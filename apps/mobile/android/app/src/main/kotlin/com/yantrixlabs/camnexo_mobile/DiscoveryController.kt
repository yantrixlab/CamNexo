package com.yantrixlabs.camnexo_mobile

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import java.net.Inet4Address

/**
 * Finds computers running the CamNexo desktop app on the same network. The desktop announces
 * `_camnexo._tcp` over mDNS; each hit is resolved to an IPv4 address and port and reported as a
 * "found" event. "lost" events carry just the service name.
 */
class DiscoveryController(
    context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private companion object {
        const val TAG = "CamNexoDiscovery"
        const val SERVICE_TYPE = "_camnexo._tcp"
    }

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.DiscoveryListener? = null

    // NsdManager resolves one service at a time, so resolutions are queued.
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    @Synchronized
    fun start() {
        if (listener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "Discovery started for $serviceType")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                Log.i(TAG, "Found ${info.serviceName} (${info.serviceType})")
                if (info.serviceType.startsWith(SERVICE_TYPE)) enqueue(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                Log.i(TAG, "Lost ${info.serviceName}")
                emit(mapOf("type" to "lost", "name" to info.serviceName))
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "Discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Start discovery failed: $errorCode")
                synchronized(this@DiscoveryController) { listener = null }
                emit(mapOf("type" to "error", "message" to "Discovery failed ($errorCode)"))
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Stop discovery failed: $errorCode")
            }
        }
        listener = l
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            Log.e(TAG, "discoverServices threw", e)
            listener = null
            emit(mapOf("type" to "error", "message" to "Discovery failed (${e.message})"))
        }
    }

    @Synchronized
    fun stop() {
        val l = listener ?: return
        listener = null
        pending.clear()
        try {
            nsd.stopServiceDiscovery(l)
        } catch (e: Exception) {
            Log.w(TAG, "stopServiceDiscovery: ${e.message}")
        }
    }

    @Synchronized
    private fun enqueue(info: NsdServiceInfo) {
        pending.addLast(info)
        resolveNext()
    }

    @Synchronized
    private fun resolveNext() {
        if (resolving) return
        val info = pending.removeFirstOrNull() ?: return
        resolving = true
        @Suppress("DEPRECATION")
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Resolve ${serviceInfo.serviceName} failed: $errorCode")
                finishResolve()
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                val host = serviceInfo.host
                val address = (host as? Inet4Address)?.hostAddress ?: host?.hostAddress
                Log.i(TAG, "Resolved ${serviceInfo.serviceName} -> $address:${serviceInfo.port}")
                if (address != null) {
                    emit(
                        mapOf(
                            "type" to "found",
                            "name" to serviceInfo.serviceName,
                            "host" to address,
                            "port" to serviceInfo.port,
                        )
                    )
                }
                finishResolve()
            }
        })
    }

    @Synchronized
    private fun finishResolve() {
        resolving = false
        resolveNext()
    }
}
