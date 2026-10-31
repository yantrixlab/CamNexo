package com.camnexo.webcam

import android.app.Activity
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Size
import android.view.OrientationEventListener
import android.view.Surface
import android.view.WindowManager
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Captures the camera with CameraX straight into a hardware H.264 encoder and sends
 * CamNexo protocol v1 packets (see docs/PROTOCOL.md) over a TCP socket.
 *
 * The computer controls the stream over the same connection: picture orientation and resolution.
 * The phone reports which resolutions its camera and hardware encoder really support, and can
 * switch to another one while streaming (the camera and encoder are rebuilt; the connection stays).
 *
 * One instance lives for the whole process and does not depend on the screen: the camera is bound
 * to its own always-started lifecycle and a foreground service ([StreamService]) keeps the process
 * and the camera alive, so streaming carries on when the app is minimised or another app is open.
 */
class StreamController private constructor(private val appContext: Context) {
    private class Packet(val header: ByteArray, val payload: ByteArray, val keyOrConfig: Boolean)

    /** A lifecycle that stays STARTED, so CameraX keeps the camera open whatever the screen does. */
    private class CameraLifecycle : LifecycleOwner {
        private val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
        fun startUp() { registry.currentState = Lifecycle.State.STARTED }
        fun shutDown() { registry.currentState = Lifecycle.State.DESTROYED }
    }

    companion object {
        private const val TAG = "CamNexoStream"
        private const val FPS = 30
        private const val AUTO_CEILING_HEIGHT = 1080  // Auto never starts above Full HD

        @Volatile private var instance: StreamController? = null

        fun get(context: Context): StreamController =
            instance ?: synchronized(this) {
                instance ?: StreamController(context.applicationContext).also { instance = it }
            }

        /** The running controller, if there is one (used by the service's Stop button). */
        fun existing(): StreamController? = instance
    }

    /** Where status events go; the screen sets this when it is showing and clears it when it goes. */
    @Volatile var emit: (Map<String, Any?>) -> Unit = {}

    /** The visible screen, only used to keep the display on while it is in front. */
    @Volatile var activity: Activity? = null

    private var cameraOwner: CameraLifecycle? = null

    private val mainExecutor = ContextCompat.getMainExecutor(appContext)
    private val cameraExecutor = Executors.newSingleThreadExecutor()
    private val running = AtomicBoolean(false)
    private val queue = LinkedBlockingQueue<Packet>(8)

    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var socket: Socket? = null
    private var front = false

    private val seq = AtomicInteger(0)
    private val bytesSent = AtomicLong(0)
    private val framesSent = AtomicInteger(0)
    private val framesDropped = AtomicInteger(0)
    private val waitingForKey = AtomicBoolean(false)

    /** Bumped whenever the encoder is replaced, so the old drain thread stops. */
    private val encoderGen = AtomicInteger(0)

    @Volatile private var width = 0
    @Volatile private var height = 0

    /** Clockwise rotation that makes the encoded picture upright, from CameraX. Sent in every packet. */
    @Volatile private var rotationDegrees = 0

    private var previewUseCase: Preview? = null
    private var orientationListener: OrientationEventListener? = null

    /** Set from the desktop app: 0 follow the phone's sensor, 1 landscape, 2 portrait. */
    @Volatile private var orientationMode = 0
    @Volatile private var orientationFlip = false

    // Resolution: the 16:9 sizes this camera and the hardware encoder both support, the size the
    // computer asked for (null = Auto), and the highest height Auto may use right now.
    @Volatile private var supportedSizes: List<Size> = emptyList()
    @Volatile private var requestedSize: Size? = null
    @Volatile private var autoCeilingHeight = AUTO_CEILING_HEIGHT

    val isRunning: Boolean get() = running.get()

    fun start(host: String, port: Int, front: Boolean) {
        if (!running.compareAndSet(false, true)) return
        this.front = front
        emit(mapOf("state" to "connecting"))
        // The foreground service lets the camera keep running when the app is not on screen.
        // Android only allows starting it while the app is visible.
        try {
            StreamService.begin(appContext)
        } catch (e: Exception) {
            fail("Could not keep the camera running in the background (${e.message})", e)
            return
        }
        Thread {
            try {
                val s = Socket()
                s.tcpNoDelay = true
                s.sendBufferSize = 512 * 1024
                s.connect(InetSocketAddress(host, port), 4000)
                socket = s
                // Tell the computer which phone this is (shown in its camera list).
                val phone = ("${Build.MANUFACTURER} ${Build.MODEL}").trim().replaceFirstChar { it.uppercase() }
                enqueueControl(byteArrayOf(4) + phone.toByteArray(Charsets.UTF_8).take(60).toByteArray())
                supportedSizes = querySupportedSizes(front)
                Log.i(TAG, "Supported 16:9 sizes: ${supportedSizes.joinToString { "${it.width}x${it.height}" }}")
                Thread { sendLoop(s) }.apply { isDaemon = true; start() }
                Thread { statsLoop() }.apply { isDaemon = true; start() }
                Thread { controlLoop(s) }.apply { isDaemon = true; start() }
                mainExecutor.execute { bindCamera() }
            } catch (e: Exception) {
                fail("Could not connect to $host:$port (${e.message})", e)
            }
        }.apply { isDaemon = true }.start()
    }

    // ------------------------------------------------------------------ resolution

    /** Bitrate that keeps a 30 fps picture clean at this size, within what Wi-Fi can carry. */
    private fun bitrateFor(w: Int, h: Int): Int {
        val bits = (w.toLong() * h * FPS * 0.13).toLong()
        return bits.coerceIn(1_000_000L, 35_000_000L).toInt()
    }

    /** The size to capture now: what the computer asked for, or the Auto choice. */
    private fun targetSize(): Size {
        requestedSize?.let { r -> if (supportedSizes.contains(r)) return r }
        val sizes = supportedSizes
        if (sizes.isEmpty()) return Size(1280, 720)
        // Auto: the largest size up to the current ceiling (Full HD at first, lower if the link struggles).
        return sizes.filter { it.height <= autoCeilingHeight }.maxByOrNull { it.width * it.height }
            ?: sizes.minByOrNull { it.width * it.height }!!
    }

    /** 16:9 sizes the chosen camera can output and the hardware H.264 encoder can encode at 30 fps. */
    private fun querySupportedSizes(front: Boolean): List<Size> {
        val fallback = listOf(Size(1280, 720))
        try {
            val manager = appContext.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val facing = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
            val chars = manager.cameraIdList
                .map { manager.getCameraCharacteristics(it) }
                .firstOrNull { c ->
                    c.get(CameraCharacteristics.LENS_FACING) == facing &&
                        (c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: intArrayOf())
                            .contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE)
                } ?: return fallback
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return fallback
            val videoCaps = findHardwareAvcEncoder()?.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)?.videoCapabilities
            val sizes = (map.getOutputSizes(SurfaceTexture::class.java) ?: emptyArray())
                .filter { it.width * 9 == it.height * 16 && it.width >= 640 }
                .filter { videoCaps == null || videoCaps.areSizeAndRateSupported(it.width, it.height, FPS.toDouble()) }
                .distinct()
                .sortedBy { it.width * it.height }
            return sizes.ifEmpty { fallback }
        } catch (e: Exception) {
            Log.w(TAG, "Could not list sizes: ${e.message}")
            return fallback
        }
    }

    private fun findHardwareAvcEncoder(): MediaCodecInfo? =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) } }
            .sortedBy { it.name.startsWith("c2.android") || it.name.startsWith("OMX.google") }
            .firstOrNull()

    /** Computer asked for another resolution (null = Auto): rebuild camera and encoder at that size. */
    private fun applyResolution(size: Size?) {
        if (!running.get() || provider == null) return
        requestedSize = size
        if (size == null) autoCeilingHeight = AUTO_CEILING_HEIGHT
        val target = targetSize()
        Log.i(TAG, "Resolution request: ${size?.let { "${it.width}x${it.height}" } ?: "auto"} -> target ${target.width}x${target.height}")
        if (target.width == width && target.height == height && encoder != null) {
            sendCapabilities()  // nothing to rebuild, just confirm the setting
            return
        }
        rebind()
    }

    /** Tears the encoder and camera binding down and builds them again at the current target size. */
    private fun rebind() {
        teardownEncoder()
        waitingForKey.set(false)
        bindCamera()
    }

    private fun teardownEncoder() {
        encoderGen.incrementAndGet()
        val e = encoder
        encoder = null
        try {
            e?.stop()
        } catch (_: Exception) {
        }
        try {
            e?.release()
        } catch (_: Exception) {
        }
        inputSurface?.release()
        inputSurface = null
        queue.clear()
    }

    /** Tells the computer which sizes are available and which one is active (control packet, kind 3). */
    private fun sendCapabilities() {
        val sizes = supportedSizes
        if (sizes.isEmpty() || width == 0) return
        val body = ByteBuffer.allocate(1 + 1 + sizes.size * 4 + 4 + 1).order(ByteOrder.LITTLE_ENDIAN)
        body.put(3)                                    // kind: capabilities
        body.put(sizes.size.toByte())
        for (s in sizes) { body.putShort(s.width.toShort()); body.putShort(s.height.toShort()) }
        body.putShort(width.toShort())                 // current size
        body.putShort(height.toShort())
        body.put(if (requestedSize == null) 1 else 0)  // 1 = Auto
        enqueueControl(body.array())
    }

    private fun enqueueControl(payload: ByteArray) {
        val header = ByteBuffer.allocate(28).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(1)                    // version
            put(2)                    // packet type: control
            put(0)
            put(0)
            putInt(seq.getAndIncrement())
            putLong(0)
            putShort(0)
            putShort(0)
            putInt(payload.size)
            putShort(0)
            putShort(0)
        }.array()
        queue.offer(Packet(header, payload, true))
    }

    // --------------------------------------------------------------- camera + encoder

    private fun bindCamera() {
        val preferred = targetSize()
        val bitrate = bitrateFor(preferred.width, preferred.height)
        val future = ProcessCameraProvider.getInstance(appContext)
        future.addListener({
            try {
                val p = future.get()
                provider = p
                val selector = ResolutionSelector.Builder()
                    // The desktop output is 16:9; a 4:3 stream would be squashed when scaled.
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(
                        ResolutionStrategy(preferred, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
                    )
                    .build()
                val preview = Preview.Builder().setResolutionSelector(selector).build()
                preview.setSurfaceProvider(cameraExecutor) { request ->
                    // The encoder is sized to whatever resolution CameraX negotiated with the camera.
                    val size = request.resolution
                    // The buffer arrives in sensor orientation; CameraX tells us how to rotate it upright.
                    request.setTransformationInfoListener(cameraExecutor) { info ->
                        rotationDegrees = info.rotationDegrees
                        Log.i(TAG, "Rotation to upright: ${info.rotationDegrees} deg")
                    }
                    try {
                        val surface = startEncoder(size.width, size.height, bitrate)
                        request.provideSurface(surface, cameraExecutor) { }
                    } catch (e: Exception) {
                        request.willNotProvideSurface()
                        fail("Encoder failed at ${size.width}x${size.height} (${e.message})", e)
                    }
                }
                val cameraSelector =
                    if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
                p.unbindAll()
                previewUseCase = preview
                val owner = cameraOwner ?: CameraLifecycle().also { it.startUp(); cameraOwner = it }
                camera = p.bindToLifecycle(owner, cameraSelector, preview)
                keepScreenOn(true)
                applyOrientation()
            } catch (e: Exception) {
                fail("Camera failed (${e.message})", e)
            }
        }, mainExecutor)
    }

    private fun startEncoder(w: Int, h: Int, bitrate: Int): Surface {
        width = w
        height = h
        Log.i(TAG, "Encoder size ${w}x$h, ${bitrate / 1000} kbps, $FPS fps")

        // Encoders differ in which options they accept, so configure with progressively simpler
        // settings. Baseline + CBR is preferred: no B-frames and a steady bitrate for the link.
        class Attempt(val name: String, val baseline: Boolean, val cbr: Boolean, val realtime: Boolean)
        val attempts = listOf(
            Attempt("baseline+cbr+realtime", baseline = true, cbr = true, realtime = true),
            Attempt("baseline+cbr", baseline = true, cbr = true, realtime = false),
            Attempt("baseline+vbr", baseline = true, cbr = false, realtime = false),
            Attempt("cbr", baseline = false, cbr = true, realtime = false),
            Attempt("defaults", baseline = false, cbr = false, realtime = false),
        )
        var codec: MediaCodec? = null
        var lastError: Exception? = null
        for (a in attempts) {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                if (a.cbr) {
                    setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                }
                if (a.baseline) {
                    setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
                }
                if (a.realtime) setInteger(MediaFormat.KEY_PRIORITY, 0)
            }
            val candidate = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            try {
                candidate.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec = candidate
                Log.i(TAG, "Encoder configured: ${a.name} (${candidate.name})")
                break
            } catch (e: Exception) {
                Log.w(TAG, "Encoder config '${a.name}' rejected on ${candidate.name}: ${e.message}")
                lastError = e
                candidate.release()
            }
        }
        if (codec == null) throw lastError ?: IOException("No H.264 encoder configuration worked")
        val surface = codec.createInputSurface()
        codec.start()
        encoder = codec
        inputSurface = surface

        // If CameraX could not give the exact size that was asked for, do not offer it again.
        requestedSize?.let { r ->
            if ((r.width != w || r.height != h) && supportedSizes.contains(r)) {
                Log.w(TAG, "Camera could not provide ${r.width}x${r.height}; using ${w}x$h")
                supportedSizes = supportedSizes.filter { it != r }
                requestedSize = Size(w, h)
            }
        }

        val gen = encoderGen.get()
        Thread { drainEncoder(codec, gen) }.apply { isDaemon = true; start() }

        val info = camera?.cameraInfo?.zoomState?.value
        emit(
            mapOf(
                "state" to "streaming",
                "width" to w,
                "height" to h,
                "minZoom" to (info?.minZoomRatio ?: 1f).toDouble(),
                "maxZoom" to (info?.maxZoomRatio ?: 1f).toDouble(),
            )
        )
        sendCapabilities()
        return surface
    }

    private fun drainEncoder(codec: MediaCodec, gen: Int) {
        val info = MediaCodec.BufferInfo()
        while (running.get() && encoderGen.get() == gen) {
            val index = try {
                codec.dequeueOutputBuffer(info, 100_000)
            } catch (e: Exception) {
                break
            }
            if (index < 0) continue
            val buf = codec.getOutputBuffer(index)
            if (buf != null && info.size > 0 && encoderGen.get() == gen) {
                buf.position(info.offset)
                buf.limit(info.offset + info.size)
                val data = ByteArray(info.size)
                buf.get(data)
                val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                enqueue(data, info.presentationTimeUs, config, key)
            }
            try {
                codec.releaseOutputBuffer(index, false)
            } catch (e: Exception) {
                break
            }
        }
    }

    private fun enqueue(data: ByteArray, ptsUs: Long, config: Boolean, key: Boolean) {
        // After a drop the decoder cannot use delta frames; skip them until the next keyframe.
        if (waitingForKey.get() && !key && !config) {
            framesDropped.incrementAndGet()
            return
        }
        val type = if (key) 1 else 0
        val flags = if (config) 1 else 0
        val header = ByteBuffer.allocate(28).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(1)                       // version
            put(type.toByte())           // 0 video, 1 keyframe
            put(0)                       // codec: H.264
            put(flags.toByte())
            putInt(seq.getAndIncrement())
            putLong(ptsUs)
            putShort(width.toShort())
            putShort(height.toShort())
            putInt(data.size)
            putShort(rotationDegrees.toShort())  // clockwise degrees to make the picture upright
            putShort(0)                  // reserved
        }.array()
        val packet = Packet(header, data, key || config)
        if (key) {
            // A fresh keyframe supersedes anything queued behind a stall.
            if (waitingForKey.get()) queue.clear()
            waitingForKey.set(false)
        }
        if (!queue.offer(packet)) {
            // Link is slower than the encoder: drop, then ask for a keyframe to resync.
            queue.clear()
            framesDropped.incrementAndGet()
            waitingForKey.set(true)
            try {
                encoder?.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            } catch (_: Exception) {
            }
            if (config) queue.offer(packet)
        }
    }

    // ------------------------------------------------------------------ threads

    private fun sendLoop(sock: Socket) {
        try {
            val out = BufferedOutputStream(sock.getOutputStream(), 64 * 1024)
            while (running.get()) {
                val p = queue.poll(200, TimeUnit.MILLISECONDS) ?: continue
                out.write(p.header)
                out.write(p.payload)
                out.flush()
                bytesSent.addAndGet((p.header.size + p.payload.size).toLong())
                if (p.header[1].toInt() != 2 && p.header[3].toInt() and 1 == 0) framesSent.incrementAndGet()
            }
        } catch (e: IOException) {
            if (running.get()) fail("Connection lost (${e.message})", e)
        }
    }

    /** Reads commands the computer sends back on the same connection (packet type 2). */
    private fun controlLoop(sock: Socket) {
        try {
            val input = DataInputStream(sock.getInputStream())
            val header = ByteArray(28)
            while (running.get()) {
                input.readFully(header)
                val type = header[1].toInt()
                val len = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).getInt(20)
                if (len < 0 || len > 4096) break
                val payload = ByteArray(len)
                if (len > 0) input.readFully(payload)
                if (type != 2 || len < 1) continue
                val body = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
                when (payload[0].toInt()) {
                    // { 1, mode, flip }: lock the picture orientation (see docs/PROTOCOL.md)
                    1 -> if (len >= 3) {
                        orientationMode = payload[1].toInt()
                        orientationFlip = payload[2].toInt() != 0
                        Log.i(TAG, "Orientation from computer: mode=$orientationMode flip=$orientationFlip")
                        mainExecutor.execute { applyOrientation() }
                    }
                    // { 2, u16 width, u16 height }: capture at this size; 0x0 means Auto
                    2 -> if (len >= 5) {
                        val w = body.getShort(1).toInt() and 0xFFFF
                        val h = body.getShort(3).toInt() and 0xFFFF
                        mainExecutor.execute { applyResolution(if (w == 0 || h == 0) null else Size(w, h)) }
                    }
                }
            }
        } catch (_: IOException) {
            // the sender loop reports a lost connection
        }
    }

    private fun statsLoop() {
        var lastBytes = 0L
        var lastFrames = 0
        var lastDropped = 0
        var strugglingSeconds = 0
        var tick = 0
        while (running.get()) {
            try {
                Thread.sleep(1000)
            } catch (e: InterruptedException) {
                return
            }
            tick++
            val bytes = bytesSent.get()
            val frames = framesSent.get()
            val dropped = framesDropped.get()
            val zoom = camera?.cameraInfo?.zoomState?.value
            emit(
                mapOf(
                    "state" to "stats",
                    "orientation" to when (orientationMode) { 1 -> "landscape"; 2 -> "portrait"; else -> "auto" },
                    "flip" to orientationFlip,
                    "width" to width,
                    "height" to height,
                    "minZoom" to (zoom?.minZoomRatio ?: 1f).toDouble(),
                    "maxZoom" to (zoom?.maxZoomRatio ?: 1f).toDouble(),
                    "fps" to (frames - lastFrames),
                    "kbps" to ((bytes - lastBytes) * 8 / 1000).toInt(),
                    "dropped" to dropped,
                )
            )
            // Keep the computer's resolution list current even if it attached late.
            if (tick % 3 == 0) sendCapabilities()

            // Auto: if the link keeps dropping frames, step down one size.
            if (requestedSize == null && dropped - lastDropped >= 8) strugglingSeconds++ else strugglingSeconds = 0
            if (strugglingSeconds >= 3) {
                val lower = supportedSizes.filter { it.height < height }.maxByOrNull { it.height }
                if (lower != null) {
                    Log.w(TAG, "Auto: link is struggling at ${width}x$height, stepping down to ${lower.width}x${lower.height}")
                    autoCeilingHeight = lower.height
                    strugglingSeconds = 0
                    mainExecutor.execute { applyResolution(null) }
                }
            }
            lastBytes = bytes
            lastFrames = frames
            lastDropped = dropped
        }
    }

    // ------------------------------------------------------------------ orientation

    /** Applies the computer's orientation setting: a fixed rotation, or follow the sensor. */
    private fun applyOrientation() {
        val preview = previewUseCase ?: return
        when (orientationMode) {
            1 -> {
                stopOrientationTracking()
                preview.targetRotation = if (orientationFlip) Surface.ROTATION_270 else Surface.ROTATION_90
            }
            2 -> {
                stopOrientationTracking()
                preview.targetRotation = if (orientationFlip) Surface.ROTATION_180 else Surface.ROTATION_0
            }
            else -> startOrientationTracking()
        }
    }

    private fun stopOrientationTracking() {
        orientationListener?.disable()
        orientationListener = null
    }

    /**
     * Follows how the phone is physically held (not the screen rotation), so the picture stays
     * upright when the phone is turned between portrait and landscape while streaming.
     */
    private fun startOrientationTracking() {
        orientationListener?.disable()
        val listener = object : OrientationEventListener(appContext) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return  // phone lying flat
                val rotation = when (orientation) {
                    in 45..134 -> Surface.ROTATION_270
                    in 135..224 -> Surface.ROTATION_180
                    in 225..314 -> Surface.ROTATION_90
                    else -> Surface.ROTATION_0
                }
                previewUseCase?.targetRotation = rotation
            }
        }
        if (listener.canDetectOrientation()) listener.enable()
        orientationListener = listener
    }

    // --------------------------------------------------------------------- controls

    /**
     * Switches between the front and back camera without dropping the connection. The sizes this
     * camera supports are listed again, and a size the new camera cannot do falls back to Auto.
     */
    fun switchCamera(useFront: Boolean) {
        mainExecutor.execute {
            val p = provider
            if (!running.get() || p == null || useFront == front) return@execute
            val selector = if (useFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            if (!p.hasCamera(selector)) {
                Log.w(TAG, "Switch camera: this phone has no ${if (useFront) "front" else "back"} camera")
                return@execute
            }
            Log.i(TAG, "Switching to the ${if (useFront) "front" else "back"} camera")
            front = useFront
            supportedSizes = querySupportedSizes(useFront)
            val r = requestedSize
            if (r != null && !supportedSizes.contains(r)) requestedSize = null
            autoCeilingHeight = AUTO_CEILING_HEIGHT
            rebind()
        }
    }

    fun setTorch(on: Boolean) {
        camera?.cameraControl?.enableTorch(on)
    }

    fun setZoom(ratio: Float) {
        camera?.cameraControl?.setZoomRatio(ratio)
    }

    /** Keeps the display on while the app is in front and streaming (no effect in the background). */
    fun keepScreenOn(on: Boolean) {
        val window = activity?.window ?: return
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    /** Tells a screen that attaches while a stream is already running what is going on. */
    fun replayState() {
        if (!running.get() || width == 0) return
        val zoom = camera?.cameraInfo?.zoomState?.value
        emit(
            mapOf(
                "state" to "streaming",
                "width" to width,
                "height" to height,
                "minZoom" to (zoom?.minZoomRatio ?: 1f).toDouble(),
                "maxZoom" to (zoom?.maxZoomRatio ?: 1f).toDouble(),
            )
        )
    }

    private fun fail(message: String, cause: Throwable? = null) {
        Log.e(TAG, message, cause)
        emit(mapOf("state" to "error", "message" to message))
        stop(emitIdle = false)
    }

    fun stop(emitIdle: Boolean = true) {
        if (!running.compareAndSet(true, false)) return
        mainExecutor.execute {
            orientationListener?.disable()
            orientationListener = null
            previewUseCase = null
            try {
                provider?.unbindAll()
            } catch (_: Exception) {
            }
            camera = null
            cameraOwner?.shutDown()
            cameraOwner = null
            keepScreenOn(false)
        }
        StreamService.end(appContext)
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        teardownEncoder()
        orientationMode = 0
        orientationFlip = false
        requestedSize = null
        autoCeilingHeight = AUTO_CEILING_HEIGHT
        supportedSizes = emptyList()
        width = 0
        height = 0
        seq.set(0)
        bytesSent.set(0)
        framesSent.set(0)
        framesDropped.set(0)
        waitingForKey.set(false)
        if (emitIdle) emit(mapOf("state" to "idle"))
    }
}
