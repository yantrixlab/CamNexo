// CamNexo desktop receiver (development build).
//   TCP :7878  <- phone (CamNexo protocol v1, H.264 Annex B)
//   Media Foundation H.264 decoder -> NV12 1280x720
//   named pipe -> camnexo_vcam_source.dll (virtual camera)
//
// Run `camnexo_vcam run` (creates the virtual camera) and `camnexo_receiver` side by side.

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <sddl.h>
#include <mfapi.h>
#include <mfidl.h>
#include <windns.h>
#include <mftransform.h>
#include <mferror.h>
#include <wmcodecdsp.h>
#include <codecapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "frame_pipe.h"

using Microsoft::WRL::ComPtr;

namespace {

constexpr unsigned short kPort = 7878;
constexpr size_t kHeaderLen = 28;
constexpr uint32_t kMaxPayload = 16 * 1024 * 1024;
constexpr uint8_t kFlagConfig = 1;

// ---------- latest decoded frame, shared with pipe clients ----------

struct FrameBus {
    std::mutex m;
    std::condition_variable cv;
    std::vector<BYTE> nv12;
    uint32_t w = 0;
    uint32_t h = 0;
    uint64_t seq = 0;
    uint64_t ts100ns = 0;
} g_bus;

// How the output frame is composed, set from the desktop window (see H264Decoder::ScaleNv12):
// 0 = Auto (fit), 1 = Landscape frame, 2 = Portrait frame; flip turns the picture 180 degrees.
std::atomic<int> g_layoutMode{0};
std::atomic<int> g_layoutFlip{0};

// Optional debugging aid: `camnexo_receiver --snap frame.bmp` rewrites the file with the latest
// frame about every 2 seconds, so the picture can be checked without a video app.
std::wstring g_snapPath;

void SaveBmp(const wchar_t* path, const BYTE* nv12, int w, int h) {
    std::vector<BYTE> rgb(static_cast<size_t>(w) * h * 3);
    const BYTE* uv = nv12 + static_cast<size_t>(w) * h;
    auto clamp = [](int v) { return static_cast<BYTE>(v < 0 ? 0 : v > 255 ? 255 : v); };
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const int Y = nv12[y * w + x] - 16;
            const int U = uv[(y / 2) * w + (x / 2) * 2] - 128;
            const int V = uv[(y / 2) * w + (x / 2) * 2 + 1] - 128;
            const int c = 298 * Y;
            BYTE* p = &rgb[(static_cast<size_t>(h - 1 - y) * w + x) * 3];
            p[0] = clamp((c + 516 * U + 128) >> 8);
            p[1] = clamp((c - 100 * U - 208 * V + 128) >> 8);
            p[2] = clamp((c + 409 * V + 128) >> 8);
        }
    }
    BITMAPFILEHEADER fh{};
    BITMAPINFOHEADER ih{};
    fh.bfType = 0x4D42;
    fh.bfOffBits = sizeof(fh) + sizeof(ih);
    fh.bfSize = fh.bfOffBits + static_cast<DWORD>(rgb.size());
    ih.biSize = sizeof(ih);
    ih.biWidth = w;
    ih.biHeight = h;
    ih.biPlanes = 1;
    ih.biBitCount = 24;
    ih.biCompression = BI_RGB;
    FILE* f = _wfopen(path, L"wb");
    if (!f) return;
    fwrite(&fh, sizeof(fh), 1, f);
    fwrite(&ih, sizeof(ih), 1, f);
    fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
}

void Publish(const BYTE* nv12, uint32_t w, uint32_t h, uint64_t ts100ns) {
    if (!g_snapPath.empty()) {
        static auto last = std::chrono::steady_clock::now() - std::chrono::seconds(10);
        const auto now = std::chrono::steady_clock::now();
        if (now - last >= std::chrono::seconds(2)) {
            last = now;
            SaveBmp(g_snapPath.c_str(), nv12, static_cast<int>(w), static_cast<int>(h));
        }
    }
    {
        std::lock_guard<std::mutex> l(g_bus.m);
        g_bus.nv12.assign(nv12, nv12 + static_cast<size_t>(w) * h * 3 / 2);
        g_bus.w = w;
        g_bus.h = h;
        g_bus.ts100ns = ts100ns;
        ++g_bus.seq;
    }
    g_bus.cv.notify_all();
}

// ---------- pipe server ----------

bool WriteAll(HANDLE h, const void* data, size_t len) {
    const BYTE* p = static_cast<const BYTE*>(data);
    while (len) {
        DWORD n = 0;
        if (!WriteFile(h, p, static_cast<DWORD>(len), &n, nullptr) || n == 0) return false;
        p += n;
        len -= n;
    }
    return true;
}

// Full-size frames for the virtual camera (NV12, any size up to 4K, size in the header).
void PipeClient(HANDLE pipe) {
    std::printf("[pipe] virtual camera connected\n");
    uint64_t last = 0;
    std::vector<BYTE> local;
    for (;;) {
        FramePipeHeader hdr{kFramePipeMagic, 0, 0, 0, 0};
        {
            std::unique_lock<std::mutex> lk(g_bus.m);
            g_bus.cv.wait(lk, [&] { return g_bus.seq != last; });
            local = g_bus.nv12;
            hdr.width = g_bus.w;
            hdr.height = g_bus.h;
            hdr.timestamp100ns = g_bus.ts100ns;
            last = g_bus.seq;
        }
        if (!WriteAll(pipe, &hdr, sizeof(hdr)) || !WriteAll(pipe, local.data(), local.size())) break;
    }
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    std::printf("[pipe] virtual camera disconnected\n");
}

// Small RGBA frames for the desktop window's preview (about 15 per second, always 640x360).
void PreviewClient(HANDLE pipe) {
    uint64_t last = 0;
    std::vector<BYTE> local, rgba(static_cast<size_t>(kPreviewWidth) * kPreviewHeight * 4);
    auto lastWrite = std::chrono::steady_clock::now() - std::chrono::seconds(1);
    for (;;) {
        FramePipeHeader hdr{kFramePipeMagic, kPreviewWidth, kPreviewHeight, 0, 0};
        uint32_t w, h;
        {
            std::unique_lock<std::mutex> lk(g_bus.m);
            g_bus.cv.wait(lk, [&] { return g_bus.seq != last; });
            last = g_bus.seq;
            if (std::chrono::steady_clock::now() - lastWrite < std::chrono::milliseconds(60)) continue;
            local = g_bus.nv12;
            w = g_bus.w;
            h = g_bus.h;
            hdr.timestamp100ns = g_bus.ts100ns;
        }
        lastWrite = std::chrono::steady_clock::now();
        if (w < 2 || h < 2) continue;
        const BYTE* uv = local.data() + static_cast<size_t>(w) * h;
        BYTE* o = rgba.data();
        auto clamp = [](int v) { return static_cast<BYTE>(v < 0 ? 0 : v > 255 ? 255 : v); };
        for (uint32_t y = 0; y < kPreviewHeight; ++y) {
            const uint32_t sy = y * h / kPreviewHeight;
            for (uint32_t x = 0; x < kPreviewWidth; ++x) {
                const uint32_t sx = x * w / kPreviewWidth;
                const int Y = local[static_cast<size_t>(sy) * w + sx] - 16;
                const BYTE* px = uv + static_cast<size_t>(sy / 2) * w + (sx & ~1u);
                const int U = px[0] - 128, V = px[1] - 128;
                const int c = 298 * Y;
                *o++ = clamp((c + 409 * V + 128) >> 8);
                *o++ = clamp((c - 100 * U - 208 * V + 128) >> 8);
                *o++ = clamp((c + 516 * U + 128) >> 8);
                *o++ = 255;
            }
        }
        if (!WriteAll(pipe, &hdr, sizeof(hdr)) || !WriteAll(pipe, rgba.data(), rgba.size())) break;
    }
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
}

void ServePipe(const wchar_t* name, void (*client)(HANDLE), DWORD outBuffer) {
    // Owner and SYSTEM full access; LocalService (the Frame Server) read/write.
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, FALSE};
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;GA;;;SY)(A;;GA;;;OW)(A;;GRGW;;;LS)", SDDL_REVISION_1, &sa.lpSecurityDescriptor, nullptr)) {
        std::fprintf(stderr, "[pipe] security descriptor failed (%lu)\n", GetLastError());
        return;
    }
    for (;;) {
        HANDLE pipe = CreateNamedPipeW(name, PIPE_ACCESS_OUTBOUND,
                                       PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                       PIPE_UNLIMITED_INSTANCES, outBuffer, 0, 0, &sa);
        if (pipe == INVALID_HANDLE_VALUE) {
            std::fprintf(stderr, "[pipe] CreateNamedPipe failed (%lu)\n", GetLastError());
            Sleep(1000);
            continue;
        }
        if (ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED) {
            std::thread(client, pipe).detach();
        } else {
            CloseHandle(pipe);
        }
    }
}

void PipeServer() { ServePipe(CAMNEXO_FRAME_PIPE, PipeClient, 16 * 1024 * 1024); }
void PreviewPipeServer() { ServePipe(CAMNEXO_PREVIEW_PIPE, PreviewClient, 2 * 1024 * 1024); }

// ---------- H.264 decoding ----------

class H264Decoder {
public:
    bool Init() {
        HRESULT hr = CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&_dec));
        if (FAILED(hr)) { std::fprintf(stderr, "[dec] create 0x%08lx\n", hr); return false; }

        ComPtr<ICodecAPI> api;
        if (SUCCEEDED(_dec.As(&api))) {
            VARIANT v;
            VariantInit(&v);
            v.vt = VT_UI4;
            v.ulVal = 1;
            api->SetValue(&CODECAPI_AVLowLatencyMode, &v);
        }

        ComPtr<IMFMediaType> in;
        MFCreateMediaType(&in);
        in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        hr = _dec->SetInputType(0, in.Get(), 0);
        if (FAILED(hr)) { std::fprintf(stderr, "[dec] SetInputType 0x%08lx\n", hr); return false; }
        if (!SelectNv12Output()) return false;

        _dec->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        _dec->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        return true;
    }

    // Feeds one Annex B access unit and publishes every picture the decoder yields.
    void Decode(const BYTE* data, size_t len, uint64_t ts100ns) {
        ComPtr<IMFMediaBuffer> buf;
        if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(len), &buf))) return;
        BYTE* dst = nullptr;
        if (FAILED(buf->Lock(&dst, nullptr, nullptr))) return;
        memcpy(dst, data, len);
        buf->Unlock();
        buf->SetCurrentLength(static_cast<DWORD>(len));
        ComPtr<IMFSample> sample;
        MFCreateSample(&sample);
        sample->AddBuffer(buf.Get());
        sample->SetSampleTime(static_cast<LONGLONG>(ts100ns));

        HRESULT hr = _dec->ProcessInput(0, sample.Get(), 0);
        if (hr == MF_E_NOTACCEPTING) {
            Drain();
            hr = _dec->ProcessInput(0, sample.Get(), 0);
        }
        if (FAILED(hr)) { ++errors; return; }
        Drain();
    }

    uint64_t decoded = 0;
    uint64_t errors = 0;
    int rotation = 0;  // clockwise degrees to make the picture upright, from the packet header

private:
    bool SelectNv12Output() {
        for (DWORD i = 0;; ++i) {
            ComPtr<IMFMediaType> t;
            if (FAILED(_dec->GetOutputAvailableType(0, i, &t))) break;
            GUID sub{};
            t->GetGUID(MF_MT_SUBTYPE, &sub);
            if (sub == MFVideoFormat_NV12) {
                if (FAILED(_dec->SetOutputType(0, t.Get(), 0))) return false;
                ReadOutputType();
                return true;
            }
        }
        std::fprintf(stderr, "[dec] no NV12 output type\n");
        return false;
    }

    void ReadOutputType() {
        ComPtr<IMFMediaType> t;
        if (FAILED(_dec->GetOutputCurrentType(0, &t))) return;
        UINT32 w = 0, h = 0;
        MFGetAttributeSize(t.Get(), MF_MT_FRAME_SIZE, &w, &h);
        _codedH = h;
        _dispW = w;
        _dispH = h;
        MFVideoArea area{};
        if (SUCCEEDED(t->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof(area), nullptr))) {
            if (area.Area.cx > 0 && area.Area.cy > 0) { _dispW = area.Area.cx; _dispH = area.Area.cy; }
        }
        UINT32 stride = 0;
        if (SUCCEEDED(t->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))) _stride = static_cast<LONG>(stride);
        else _stride = static_cast<LONG>(w);
        std::printf("[dec] output NV12 %ux%u (display %ux%u, stride %ld)\n", w, h, _dispW, _dispH, _stride);
    }

    void Drain() {
        for (;;) {
            MFT_OUTPUT_STREAM_INFO info{};
            _dec->GetOutputStreamInfo(0, &info);
            ComPtr<IMFSample> own;
            MFT_OUTPUT_DATA_BUFFER out{};
            out.dwStreamID = 0;
            const bool provides =
                info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES);
            if (!provides) {
                ComPtr<IMFMediaBuffer> b;
                MFCreateAlignedMemoryBuffer(info.cbSize, info.cbAlignment, &b);
                MFCreateSample(&own);
                own->AddBuffer(b.Get());
                out.pSample = own.Get();
            }
            DWORD status = 0;
            HRESULT hr = _dec->ProcessOutput(0, 1, &out, &status);
            if (out.pEvents) out.pEvents->Release();
            ComPtr<IMFSample> got;
            if (provides) got.Attach(out.pSample);
            else got = own;

            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return;
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE) { SelectNv12Output(); continue; }
            if (FAILED(hr)) { ++errors; return; }
            if (got) Emit(got.Get());
        }
    }

    void Emit(IMFSample* sample) {
        ComPtr<IMFMediaBuffer> buf;
        if (FAILED(sample->ConvertToContiguousBuffer(&buf))) return;
        ComPtr<IMF2DBuffer> b2;
        BYTE* scan = nullptr;
        LONG pitch = 0;
        BYTE* linear = nullptr;
        bool is2d = false;
        if (SUCCEEDED(buf.As(&b2)) && SUCCEEDED(b2->Lock2D(&scan, &pitch))) {
            is2d = true;
        } else {
            if (FAILED(buf->Lock(&linear, nullptr, nullptr))) return;
            scan = linear;
            pitch = _stride;
        }
        LONGLONG ts = 0;
        sample->GetSampleTime(&ts);
        if (ScaleNv12(scan, pitch)) Publish(_out.data(), _outW, _outH, static_cast<uint64_t>(ts));
        ++decoded;
        if (is2d) b2->Unlock2D();
        else buf->Unlock();
    }

    // Composes the output frame: crop to the display aperture, rotate clockwise so the picture is
    // upright (the phone works this out from its own gravity sensor), then place it in a 16:9
    // canvas (nearest neighbour) according to the layout chosen in the desktop window:
    //   Auto       fit the whole picture inside the canvas, black bars where it does not fill; the
    //              frame's shape follows how the phone is held.
    //   Landscape  the frame is always the full wide canvas. The picture is scaled to fill it and
    //              whatever overflows is cropped, so an upright phone shows a cropped strip.
    //   Portrait   the frame is always a narrow upright band in the middle of the canvas, filled
    //              the same way. Turning the phone never changes the frame in these two modes.
    // The canvas follows the decoded size: its height is the shorter side of the picture (so
    // 1920x1080 gives a 1920x1080 canvas). Returns false when there is nothing to publish; the
    // canvas size is left in _outW/_outH.
    bool ScaleNv12(const BYTE* src, LONG pitch) {
        if (_dispW == 0 || _dispH == 0) return false;
        _outH = std::min<UINT32>(kMaxFrameHeight, std::min(_dispW, _dispH)) & ~1u;
        _outW = std::min<UINT32>(kMaxFrameWidth, _outH * 16 / 9) & ~1u;
        const int outW = static_cast<int>(_outW), outH = static_cast<int>(_outH);
        if (_out.size() != static_cast<size_t>(outW) * outH * 3 / 2) _out.resize(static_cast<size_t>(outW) * outH * 3 / 2);

        // Flip turns the picture another half turn (for a phone mounted upside down).
        const int rot = (((rotation + (g_layoutFlip.load() ? 180 : 0)) % 360) + 360) % 360 / 90 * 90;
        const bool quarter = rot == 90 || rot == 270;
        const int rw = static_cast<int>(quarter ? _dispH : _dispW);  // size of the rotated picture
        const int rh = static_cast<int>(quarter ? _dispW : _dispH);

        const int layout = g_layoutMode.load();  // 0 auto, 1 landscape, 2 portrait
        double s;
        int fw, fh, ox, oy;
        double u0 = 0, v0 = 0;  // where the visible part starts inside the rotated picture
        if (layout == 0) {
            s = std::min(static_cast<double>(outW) / rw, static_cast<double>(outH) / rh);
            fw = static_cast<int>(rw * s) & ~1;
            fh = static_cast<int>(rh * s) & ~1;
            ox = ((outW - fw) / 2) & ~1;
            oy = ((outH - fh) / 2) & ~1;
        } else {
            // Landscape fills the whole canvas; portrait fills a 9:16 band in the middle.
            const int tw = layout == 2 ? ((outH * 9 / 16) & ~1) : outW;
            const int th = outH;
            s = std::max(static_cast<double>(tw) / rw, static_cast<double>(th) / rh);
            fw = tw;
            fh = th;
            ox = ((outW - tw) / 2) & ~1;
            oy = 0;
            u0 = (rw - fw / s) / 2.0;  // centre crop
            v0 = (rh - fh / s) / 2.0;
        }
        if (fw <= 0 || fh <= 0) return false;

        BYTE* dstY = _out.data();
        BYTE* dstUv = _out.data() + static_cast<size_t>(outW) * outH;

        // Fast path: upright and already the canvas size (typical for landscape): plain row copies.
        if (rot == 0 && fw == outW && fh == outH && static_cast<int>(_dispW) == outW && static_cast<int>(_dispH) == outH) {
            const BYTE* srcUv0 = src + static_cast<size_t>(pitch) * _codedH;
            for (int y = 0; y < outH; ++y) memcpy(dstY + static_cast<size_t>(y) * outW, src + static_cast<size_t>(y) * pitch, outW);
            for (int y = 0; y < outH / 2; ++y) memcpy(dstUv + static_cast<size_t>(y) * outW, srcUv0 + static_cast<size_t>(y) * pitch, outW);
            return true;
        }

        memset(dstY, 16, static_cast<size_t>(outW) * outH);       // black bars
        memset(dstUv, 128, static_cast<size_t>(outW) * outH / 2);

        // Output column/row -> coordinate in the rotated picture.
        _colU.resize(fw);
        _rowV.resize(fh);
        for (int i = 0; i < fw; ++i) _colU[i] = std::clamp(static_cast<int>(u0 + i / s), 0, rw - 1);
        for (int j = 0; j < fh; ++j) _rowV[j] = std::clamp(static_cast<int>(v0 + j / s), 0, rh - 1);

        const int dw = static_cast<int>(_dispW), dh = static_cast<int>(_dispH);
        auto toSource = [&](int u, int v, int& sx, int& sy) {
            switch (rot) {
                case 90:  sx = v;          sy = dh - 1 - u; break;
                case 180: sx = dw - 1 - u; sy = dh - 1 - v; break;
                case 270: sx = dw - 1 - v; sy = u;          break;
                default:  sx = u;          sy = v;          break;
            }
        };

        const BYTE* srcUv = src + static_cast<size_t>(pitch) * _codedH;
        for (int j = 0; j < fh; ++j) {
            BYTE* out = dstY + static_cast<size_t>(oy + j) * outW + ox;
            for (int i = 0; i < fw; ++i) {
                int sx, sy;
                toSource(_colU[i], _rowV[j], sx, sy);
                out[i] = src[static_cast<size_t>(sy) * pitch + sx];
            }
        }
        for (int j = 0; j < fh / 2; ++j) {
            BYTE* out = dstUv + static_cast<size_t>(oy / 2 + j) * outW + ox;
            for (int i = 0; i < fw / 2; ++i) {
                int sx, sy;
                toSource(_colU[2 * i], _rowV[2 * j], sx, sy);
                const BYTE* px = srcUv + static_cast<size_t>(sy / 2) * pitch + (sx / 2) * 2;
                out[i * 2] = px[0];
                out[i * 2 + 1] = px[1];
            }
        }
        return true;
    }

    ComPtr<IMFTransform> _dec;
    std::vector<int> _colU, _rowV;
    std::vector<BYTE> _out;
    UINT32 _outW = 0, _outH = 0;
    UINT32 _codedH = 0, _dispW = 0, _dispH = 0;
    LONG _stride = 0;
};

// ---------- TCP server ----------

bool RecvAll(SOCKET s, void* buf, size_t len) {
    BYTE* p = static_cast<BYTE*>(buf);
    while (len) {
        int n = recv(s, reinterpret_cast<char*>(p), static_cast<int>(len > (1 << 20) ? (1 << 20) : len), 0);
        if (n <= 0) return false;
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

// ---------- orientation control (desktop app -> phone) ----------
// The desktop app can lock how the phone orients its picture. The phone reads control packets
// (type 2) from the same socket it streams on: payload { 1, mode, flip }.
// mode: 0 follow the phone's sensor, 1 landscape, 2 portrait. flip: 1 turns it 180 degrees.

// Resolution: payload { 2, u16 width, u16 height } to the phone; 0x0 means Auto. The phone answers
// with its supported sizes: { 3, count, count x (u16 w, u16 h), u16 curW, u16 curH, auto } which is
// printed as a "[cap]" line for the desktop app.

std::atomic<int> g_resW{0};  // 0 = Auto
std::atomic<int> g_resH{0};
std::mutex g_clientMutex;
SOCKET g_clientSock = INVALID_SOCKET;

void SendControl(const BYTE* payload, uint32_t len) {
    std::lock_guard<std::mutex> l(g_clientMutex);
    if (g_clientSock == INVALID_SOCKET) return;
    std::vector<BYTE> pkt(kHeaderLen + len, 0);
    pkt[0] = 1;  // protocol version
    pkt[1] = 2;  // packet type: control
    memcpy(pkt.data() + 20, &len, sizeof(len));
    memcpy(pkt.data() + kHeaderLen, payload, len);
    send(g_clientSock, reinterpret_cast<const char*>(pkt.data()), static_cast<int>(pkt.size()), 0);
}

// The phone always follows its own motion sensor, so the picture it sends is upright however it
// is held. The frame layout (Auto, Landscape, Portrait) is applied here on the computer.
void SendOrientation() {
    const BYTE p[3] = {1, 0, 0};  // mode 0: follow the sensor
    SendControl(p, sizeof(p));
}

void SendResolution() {
    const uint16_t w = static_cast<uint16_t>(g_resW.load()), h = static_cast<uint16_t>(g_resH.load());
    BYTE p[5] = {2};
    memcpy(p + 1, &w, 2);
    memcpy(p + 3, &h, 2);
    SendControl(p, sizeof(p));
}

// Turns the phone's capability message into one line the desktop app can read.
void PrintCapabilities(const std::vector<BYTE>& p) {
    if (p.size() < 2) return;
    const size_t count = p[1];
    if (p.size() < 2 + count * 4 + 5) return;
    std::string sizes;
    for (size_t i = 0; i < count; ++i) {
        uint16_t w, h;
        memcpy(&w, p.data() + 2 + i * 4, 2);
        memcpy(&h, p.data() + 2 + i * 4 + 2, 2);
        if (!sizes.empty()) sizes += ',';
        sizes += std::to_string(w) + "x" + std::to_string(h);
    }
    uint16_t cw, ch;
    memcpy(&cw, p.data() + 2 + count * 4, 2);
    memcpy(&ch, p.data() + 2 + count * 4 + 2, 2);
    const int autoMode = p[2 + count * 4 + 4];
    std::printf("[cap] sizes=%s current=%ux%u auto=%d\n", sizes.c_str(), cw, ch, autoMode);
}

void ServeClient(SOCKET c, std::string peer) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    std::printf("[tcp] phone connected from %s\n", peer.c_str());
    H264Decoder dec;
    if (!dec.Init()) { closesocket(c); CoUninitialize(); return; }
    {
        std::lock_guard<std::mutex> l(g_clientMutex);
        g_clientSock = c;
    }
    SendOrientation();  // a phone that connects later still gets the current settings
    SendResolution();

    std::vector<BYTE> config, payload, unit;
    uint64_t bytes = 0, frames = 0, lastBytes = 0, lastFrames = 0, lastDecoded = 0;
    auto lastReport = std::chrono::steady_clock::now();
    uint32_t w = 0, h = 0;

    for (;;) {
        BYTE hdr[kHeaderLen];
        if (!RecvAll(c, hdr, kHeaderLen)) break;
        if (hdr[0] != 1) { std::fprintf(stderr, "[tcp] bad protocol version %u\n", hdr[0]); break; }
        const uint8_t type = hdr[1], flags = hdr[3];
        uint64_t ptsUs;
        uint32_t len;
        memcpy(&ptsUs, hdr + 8, 8);
        memcpy(&len, hdr + 20, 4);
        uint16_t pw, ph, rot;
        memcpy(&pw, hdr + 16, 2);
        memcpy(&ph, hdr + 18, 2);
        memcpy(&rot, hdr + 24, 2);
        if (type != 2) {  // control packets carry no rotation
            if (rot != dec.rotation) std::printf("[tcp] rotation %u -> %u degrees\n", dec.rotation, rot);
            dec.rotation = rot;
        }
        if (len > kMaxPayload) { std::fprintf(stderr, "[tcp] payload too large (%u)\n", len); break; }
        payload.resize(len);
        if (len && !RecvAll(c, payload.data(), len)) break;
        bytes += kHeaderLen + len;

        if (flags & kFlagConfig) {
            config = payload;
            w = pw; h = ph;
            std::printf("[tcp] stream %ux%u, config %u bytes\n", w, h, len);
            continue;
        }
        if (type == 2) {  // control message from the phone
            if (!payload.empty() && payload[0] == 3) PrintCapabilities(payload);
            continue;
        }
        ++frames;
        if (type == 1 && !config.empty()) {
            unit = config;
            unit.insert(unit.end(), payload.begin(), payload.end());
            dec.Decode(unit.data(), unit.size(), ptsUs * 10);
        } else {
            dec.Decode(payload.data(), payload.size(), ptsUs * 10);
        }

        auto now = std::chrono::steady_clock::now();
        if (now - lastReport >= std::chrono::seconds(1)) {
            const double secs = std::chrono::duration<double>(now - lastReport).count();
            std::printf("[rx] %.0f fps in, %.0f fps decoded, %.0f kbps, decode errors %llu\n",
                        (frames - lastFrames) / secs, (dec.decoded - lastDecoded) / secs,
                        (bytes - lastBytes) * 8 / 1000.0 / secs, static_cast<unsigned long long>(dec.errors));
            lastReport = now;
            lastBytes = bytes; lastFrames = frames; lastDecoded = dec.decoded;
        }
    }
    std::printf("[tcp] phone disconnected\n");
    {
        std::lock_guard<std::mutex> l(g_clientMutex);
        g_clientSock = INVALID_SOCKET;
    }
    closesocket(c);
    CoUninitialize();
}

// ---------- mDNS / DNS-SD announcement (_camnexo._tcp) ----------

PDNS_SERVICE_INSTANCE g_mdnsInstance = nullptr;
DNS_SERVICE_REGISTER_REQUEST g_mdnsRequest{};
std::wstring g_mdnsName;

VOID WINAPI OnMdnsRegistered(DWORD status, PVOID, PDNS_SERVICE_INSTANCE) {
    if (status == ERROR_SUCCESS) {
        std::printf("[mdns] registered as %ls\n", g_mdnsName.c_str());
    } else {
        std::printf("[mdns] registration FAILED (status %lu)\n", status);
    }
}

// Picks the IPv4 address phones are most likely to reach: private LAN ranges first.
bool PickLanAddress(IP4_ADDRESS* out) {
    char name[256]{};
    gethostname(name, sizeof(name));
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    if (getaddrinfo(name, nullptr, &hints, &res) != 0) return false;
    int bestScore = -1;
    for (addrinfo* a = res; a; a = a->ai_next) {
        const auto* sin = reinterpret_cast<sockaddr_in*>(a->ai_addr);
        const BYTE b0 = sin->sin_addr.S_un.S_un_b.s_b1, b1 = sin->sin_addr.S_un.S_un_b.s_b2;
        int score = 0;
        if (b0 == 192 && b1 == 168) score = 4;
        else if (b0 == 10) score = 3;
        else if (b0 == 172 && b1 >= 16 && b1 <= 31) score = 2;
        else if (b0 == 169 && b1 == 254) score = 0;  // link-local: last resort
        else score = 1;
        if (score > bestScore) {
            bestScore = score;
            *out = sin->sin_addr.S_un.S_addr;
        }
    }
    freeaddrinfo(res);
    return bestScore >= 0;
}

void StartMdns() {
    wchar_t host[256]{};
    DWORD len = 256;
    if (!GetComputerNameExW(ComputerNameDnsHostname, host, &len)) wcscpy_s(host, L"computer");
    std::wstring safe;
    for (wchar_t* p = host; *p; ++p) safe += (iswalnum(*p) || *p == L'-') ? *p : L'-';

    g_mdnsName = L"CamNexo-" + safe;
    const std::wstring instance = g_mdnsName + L"._camnexo._tcp.local";
    const std::wstring dnsHost = safe + L".local";
    IP4_ADDRESS ip4 = 0;
    const bool haveIp = PickLanAddress(&ip4);

    PCWSTR keys[] = {L"v", L"name"};
    PCWSTR values[] = {L"1", safe.c_str()};
    g_mdnsInstance = DnsServiceConstructInstance(instance.c_str(), dnsHost.c_str(), haveIp ? &ip4 : nullptr,
                                                 nullptr, kPort, 0, 0, 2, keys, values);
    if (!g_mdnsInstance) {
        std::printf("[mdns] could not build the service record\n");
        return;
    }
    g_mdnsRequest.Version = DNS_QUERY_REQUEST_VERSION1;
    g_mdnsRequest.InterfaceIndex = 0;  // all interfaces
    g_mdnsRequest.pServiceInstance = g_mdnsInstance;
    g_mdnsRequest.pRegisterCompletionCallback = OnMdnsRegistered;
    const DWORD r = DnsServiceRegister(&g_mdnsRequest, nullptr);
    if (r != DNS_REQUEST_PENDING && r != ERROR_SUCCESS) {
        std::printf("[mdns] registration FAILED to start (error %lu)\n", r);
    }
}

void StopMdns() {
    if (g_mdnsInstance) {
        DnsServiceDeRegister(&g_mdnsRequest, nullptr);  // sends the "goodbye" so phones drop us at once
        Sleep(300);
        DnsServiceFreeInstance(g_mdnsInstance);
        g_mdnsInstance = nullptr;
    }
}

// The desktop app talks to the receiver through stdin, one command per line:
//   quit                                  clean exit (withdraws the network announcement)
//   orientation <auto|landscape|portrait> <0|1>   output frame layout (Auto fits, Landscape and
//                                         Portrait are fixed frames that crop to fill); 1 = flip 180
//   resolution auto | resolution <w> <h>  picture size the phone captures
// EOF is ignored on purpose: the receiver can also run with no console attached.
void WatchStdin() {
    char line[96];
    while (std::fgets(line, sizeof(line), stdin)) {
        if (std::strncmp(line, "quit", 4) == 0) {
            std::printf("[mdns] withdrawing announcement\n");
            StopMdns();
            std::exit(0);
        }
        // resolution auto | resolution <width> <height>
        {
            char word[24] = {};
            int rw = 0, rh = 0;
            if (std::sscanf(line, "resolution %23s %d", word, &rh) >= 1) {
                if (std::strcmp(word, "auto") == 0) {
                    g_resW = 0;
                    g_resH = 0;
                } else if (std::sscanf(line, "resolution %d %d", &rw, &rh) == 2 && rw > 0 && rh > 0) {
                    g_resW = rw;
                    g_resH = rh;
                } else {
                    continue;
                }
                std::printf("[ctl] resolution %d x %d\n", g_resW.load(), g_resH.load());
                SendResolution();
                continue;
            }
        }
        char mode[24] = {};
        int flip = 0;
        if (std::sscanf(line, "orientation %23s %d", mode, &flip) >= 1) {
            int m = -1;
            if (std::strcmp(mode, "auto") == 0) m = 0;
            else if (std::strcmp(mode, "landscape") == 0) m = 1;
            else if (std::strcmp(mode, "portrait") == 0) m = 2;
            if (m >= 0) {
                // Applied here when composing each frame; the phone stays on its own sensor.
                g_layoutMode = m;
                g_layoutFlip = flip ? 1 : 0;
                std::printf("[ctl] layout %s flip %d\n", mode, flip ? 1 : 0);
            }
        }
    }
}

void PrintAddresses() {
    char name[256]{};
    gethostname(name, sizeof(name));
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    if (getaddrinfo(name, nullptr, &hints, &res) != 0) return;
    for (addrinfo* a = res; a; a = a->ai_next) {
        char ip[64]{};
        inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(a->ai_addr)->sin_addr, ip, sizeof(ip));
        std::printf("  phone address:  %s:%u\n", ip, kPort);
    }
    freeaddrinfo(res);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);  // logs are read from a redirected file while running
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::wstring(argv[i]) == L"--snap") g_snapPath = argv[i + 1];
    }
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);

    std::thread(PipeServer).detach();
    std::thread(PreviewPipeServer).detach();

    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(kPort);
    BOOL reuse = TRUE;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));
    if (bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(listener, 1) != 0) {
        std::fprintf(stderr, "Cannot listen on port %u (error %d). Is another receiver running?\n", kPort, WSAGetLastError());
        return 1;
    }
    std::printf("CamNexo receiver listening on TCP %u. Enter one of these in the phone app:\n", kPort);
    PrintAddresses();
    std::printf("  (USB: run `adb reverse tcp:%u tcp:%u`, then use 127.0.0.1)\n\n", kPort, kPort);
    StartMdns();
    std::thread(WatchStdin).detach();

    for (;;) {
        sockaddr_in peer{};
        int plen = sizeof(peer);
        SOCKET c = accept(listener, reinterpret_cast<sockaddr*>(&peer), &plen);
        if (c == INVALID_SOCKET) continue;
        BOOL nodelay = TRUE;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));
        char ip[64]{};
        inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
        // One phone at a time: serve inline so a second connection waits in the backlog.
        ServeClient(c, ip);
    }
}
