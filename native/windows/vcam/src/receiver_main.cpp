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
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "effects.h"
#include "frame_pipe.h"
#include "picture.h"

using Microsoft::WRL::ComPtr;

namespace {

unsigned short kPort = 7878;  // --port N changes it (development)
bool g_noDiscovery = false;  // --no-discovery: do not announce on the network
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

// ---------- cameras (one per connected phone) and the layout that composes them ----------

// Settings the desktop app chose for a phone. They are kept by the phone's address, so a phone
// that reconnects gets them back.
struct SourceSettings {
    int resW = 0;  // 0 = Auto
    int resH = 0;
    bool flip = false;
};

struct Source {
    int id = 0;
    std::string peer;
    bool simulated = false;
    std::atomic<int> rotation{0};  // clockwise degrees to make the picture upright, from the packets
    std::atomic<bool> flip{false}; // an extra half turn, for a phone mounted upside down
    std::atomic<bool> alive{true};
    SOCKET sock = INVALID_SOCKET;
    std::mutex sockMutex;
    std::mutex picMutex;
    std::shared_ptr<const Picture> latest;

    // Effects (background blur or replacement, filters). The settings come from the desktop app on
    // another thread; the processor belongs to the thread that decodes this camera.
    std::mutex fxMutex;
    std::shared_ptr<const EffectSettings> fxSettings;
    fx::Processor fxProc;
    int fxLogCounter = 0;
    double fxMsSum = 0;
};

// Runs a freshly decoded picture through the camera's effects (if any) before it is shown.
std::shared_ptr<const Picture> WithEffects(Source& s, std::shared_ptr<const Picture> pic) {
    std::shared_ptr<const EffectSettings> st;
    {
        std::lock_guard<std::mutex> l(s.fxMutex);
        st = s.fxSettings;
    }
    if (!st || !st->active()) return pic;
    const int rot = s.rotation.load() + (s.flip.load() ? 180 : 0);
    auto out = s.fxProc.Process(pic, rot, *st);
    if (st->mode != 0) {
        s.fxMsSum += s.fxProc.lastMs;
        if (++s.fxLogCounter >= 150) {  // about every five seconds: the average time per picture
            std::printf("[fx] camera %d: %.1f ms per picture, %.1f ms per matte\n", s.id, s.fxMsSum / s.fxLogCounter, s.fxProc.modelMs.load());
            s.fxLogCounter = 0;
            s.fxMsSum = 0;
        }
    }
    return out;
}

std::mutex g_srcMutex;
std::map<int, std::shared_ptr<Source>> g_sources;
std::map<std::string, SourceSettings> g_settings;
int g_nextSourceId = 1;
constexpr size_t kMaxSources = 8;

// A cell of the layout: where one camera is drawn on the canvas. x, y, w, h are fractions of the
// canvas (0..1). cover = fill the cell and crop the overflow; otherwise fit the whole picture.
struct Cell {
    int src = -1;
    double x = 0, y = 0, w = 1, h = 1;
    bool cover = false;
};

std::mutex g_layoutMutex;
std::vector<Cell> g_cells;
bool g_layoutSet = false;  // false: show the first camera, fitted, until the window sends a layout

// Wakes the compositor when a camera delivers a picture or the layout changes.
std::mutex g_composeMutex;
std::condition_variable g_composeCv;
std::atomic<bool> g_dirty{false};

void MarkDirty() {
    g_dirty = true;
    g_composeCv.notify_all();
}

std::shared_ptr<Source> FindSource(int id) {
    std::lock_guard<std::mutex> l(g_srcMutex);
    auto it = g_sources.find(id);
    return it == g_sources.end() ? nullptr : it->second;
}

// Optional debugging aid: `camnexo_receiver --snap frame.bmp` rewrites the file with the latest
// frame about every 2 seconds, so the picture can be checked without a video app.
std::wstring g_snapPath;

void SaveBmp(const wchar_t* path, const BYTE* nv12, int w, int h) {
    const size_t stride = (static_cast<size_t>(w) * 3 + 3) & ~static_cast<size_t>(3);  // rows are padded to 4 bytes
    std::vector<BYTE> rgb(stride * h);
    const BYTE* uv = nv12 + static_cast<size_t>(w) * h;
    auto clamp = [](int v) { return static_cast<BYTE>(v < 0 ? 0 : v > 255 ? 255 : v); };
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const int Y = nv12[y * w + x] - 16;
            const int U = uv[(y / 2) * w + (x / 2) * 2] - 128;
            const int V = uv[(y / 2) * w + (x / 2) * 2 + 1] - 128;
            const int c = 298 * Y;
            BYTE* p = &rgb[static_cast<size_t>(h - 1 - y) * stride + static_cast<size_t>(x) * 3];
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

// Small RGBA frames for the desktop window's preview (about 15 per second, always the preview size).
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
void PreviewPipeServer() { ServePipe(CAMNEXO_PREVIEW_PIPE, PreviewClient, 4 * 1024 * 1024); }

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
    std::function<void(std::shared_ptr<const Picture>)> onPicture;  // every decoded picture

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

    // Copies the visible part of the decoded picture into a tightly packed NV12 Picture and hands it
    // to the owner. Placing it on the canvas (rotation, fit or crop) is the compositor's job.
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
        if (_dispW >= 2 && _dispH >= 2 && pitch > 0 && onPicture) {
            auto pic = std::make_shared<Picture>();
            pic->w = _dispW & ~1u;
            pic->h = _dispH & ~1u;
            pic->ts100ns = static_cast<uint64_t>(ts);
            pic->nv12.resize(static_cast<size_t>(pic->w) * pic->h * 3 / 2);
            BYTE* dst = pic->nv12.data();
            for (uint32_t y = 0; y < pic->h; ++y) memcpy(dst + static_cast<size_t>(y) * pic->w, scan + static_cast<size_t>(y) * pitch, pic->w);
            const BYTE* srcUv = scan + static_cast<size_t>(pitch) * _codedH;
            BYTE* dstUv = dst + static_cast<size_t>(pic->w) * pic->h;
            for (uint32_t y = 0; y < pic->h / 2; ++y) memcpy(dstUv + static_cast<size_t>(y) * pic->w, srcUv + static_cast<size_t>(y) * pitch, pic->w);
            onPicture(std::move(pic));
        }
        ++decoded;
        if (is2d) b2->Unlock2D();
        else buf->Unlock();
    }

    ComPtr<IMFTransform> _dec;
    UINT32 _codedH = 0, _dispW = 0, _dispH = 0;
    LONG _stride = 0;
};

// ---------- compositor ----------

// Builds the output frame from the latest picture of every camera in the layout. Returns false
// when there is nothing to show yet.
bool ComposeFrame(std::vector<BYTE>& out, int& outW, int& outH) {
    std::vector<Cell> cells;
    bool layoutSet;
    {
        std::lock_guard<std::mutex> l(g_layoutMutex);
        cells = g_cells;
        layoutSet = g_layoutSet;
    }

    struct Drawable {
        Cell cell;
        std::shared_ptr<Source> src;
        std::shared_ptr<const Picture> pic;
    };
    std::vector<Drawable> items;
    if (!layoutSet) {
        // No layout from the window yet: show the first camera, fitted.
        std::lock_guard<std::mutex> l(g_srcMutex);
        if (!g_sources.empty()) cells.push_back(Cell{g_sources.begin()->first, 0, 0, 1, 1, false});
    }
    int cellsWithCamera = 0;
    for (const Cell& c : cells) {
        auto src = FindSource(c.src);
        if (!src) continue;
        ++cellsWithCamera;
        std::shared_ptr<const Picture> pic;
        {
            std::lock_guard<std::mutex> l(src->picMutex);
            pic = src->latest;
        }
        if (pic && pic->w >= 2 && pic->h >= 2) items.push_back({c, src, pic});
    }
    if (items.empty()) return false;

    // One camera: the canvas follows its picture (the shorter side sets the height, up to 4K).
    // Several cameras: a Full HD canvas.
    int canvasH = 1080;
    if (cellsWithCamera == 1) {
        canvasH = static_cast<int>(std::min<uint32_t>(kMaxFrameHeight, std::min(items[0].pic->w, items[0].pic->h)));
    }
    canvasH = std::max(canvasH & ~1, 2);
    int canvasW = static_cast<int>(std::min<uint32_t>(kMaxFrameWidth, static_cast<uint32_t>(canvasH) * 16 / 9)) & ~1;
    outW = canvasW;
    outH = canvasH;
    const size_t ySize = static_cast<size_t>(canvasW) * canvasH;
    out.resize(ySize * 3 / 2);
    memset(out.data(), 16, ySize);                 // black
    memset(out.data() + ySize, 128, ySize / 2);

    for (const Drawable& d : items) {
        auto px = [](double frac, int total) { return std::clamp(static_cast<int>(frac * total + 0.5), 0, total); };
        int x0 = px(d.cell.x, canvasW) & ~1, y0 = px(d.cell.y, canvasH) & ~1;
        int x1 = px(d.cell.x + d.cell.w, canvasW) & ~1, y1 = px(d.cell.y + d.cell.h, canvasH) & ~1;
        const int rot = d.pic->upright ? 0 : d.src->rotation.load() + (d.src->flip.load() ? 180 : 0);
        DrawCell(*d.pic, rot, d.cell.cover, out.data(), out.data() + ySize, canvasW, x0, y0, x1 - x0, y1 - y0);
    }
    return true;
}

void CompositorLoop() {
    std::vector<BYTE> frame;
    auto last = std::chrono::steady_clock::now() - std::chrono::seconds(1);
    for (;;) {
        {
            std::unique_lock<std::mutex> lk(g_composeMutex);
            g_composeCv.wait_for(lk, std::chrono::milliseconds(200), [] { return g_dirty.load(); });
        }
        if (!g_dirty.exchange(false)) continue;
        std::this_thread::sleep_until(last + std::chrono::milliseconds(30));  // about 33 pictures a second at most
        last = std::chrono::steady_clock::now();
        int w = 0, h = 0;
        if (ComposeFrame(frame, w, h)) {
            const uint64_t ts = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                          last.time_since_epoch()).count() / 100);
            Publish(frame.data(), static_cast<uint32_t>(w), static_cast<uint32_t>(h), ts);
        }
    }
}

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

// ---------- control (desktop app -> phone) ----------
// The phone reads control packets (type 2) from the same socket it streams on.
//   { 1, mode, flip }                    orientation. The receiver always sends mode 0: the phone
//                                        follows its own sensor and the picture is upright.
//   { 2, u16 width, u16 height }         picture size to capture; 0x0 means Auto.
// The phone sends back:
//   { 3, count, count x (u16 w, u16 h), u16 curW, u16 curH, auto }   the sizes it can do
//   { 4, utf8 text... }                  its name (for example the phone model)

void SendControl(Source& s, const BYTE* payload, uint32_t len) {
    std::lock_guard<std::mutex> l(s.sockMutex);
    if (s.sock == INVALID_SOCKET) return;
    std::vector<BYTE> pkt(kHeaderLen + len, 0);
    pkt[0] = 1;  // protocol version
    pkt[1] = 2;  // packet type: control
    memcpy(pkt.data() + 20, &len, sizeof(len));
    memcpy(pkt.data() + kHeaderLen, payload, len);
    send(s.sock, reinterpret_cast<const char*>(pkt.data()), static_cast<int>(pkt.size()), 0);
}

void SendOrientation(Source& s) {
    const BYTE p[3] = {1, 0, 0};  // mode 0: follow the sensor
    SendControl(s, p, sizeof(p));
}

void SendResolution(Source& s, int w, int h) {
    const uint16_t pw = static_cast<uint16_t>(w), ph = static_cast<uint16_t>(h);
    BYTE p[5] = {2};
    memcpy(p + 1, &pw, 2);
    memcpy(p + 3, &ph, 2);
    SendControl(s, p, sizeof(p));
}

// Turns the phone's capability message into one line the desktop app can read.
void PrintCapabilities(int id, const std::vector<BYTE>& p) {
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
    std::printf("[src %d] cap sizes=%s current=%ux%u auto=%d\n", id, sizes.c_str(), cw, ch, autoMode);
}

// Takes a camera out of the list (its connection ended) and lets the compositor redraw.
void RemoveSource(const std::shared_ptr<Source>& src) {
    src->alive = false;
    {
        std::lock_guard<std::mutex> l(g_srcMutex);
        g_sources.erase(src->id);
    }
    std::printf("[src %d] disconnected\n", src->id);
    MarkDirty();
}

// Registers a new camera and returns it, or null when the limit is reached.
std::shared_ptr<Source> AddSource(const std::string& peer, bool simulated, SourceSettings* settingsOut) {
    std::lock_guard<std::mutex> l(g_srcMutex);
    if (g_sources.size() >= kMaxSources) return nullptr;
    auto src = std::make_shared<Source>();
    src->id = g_nextSourceId++;
    src->peer = peer;
    src->simulated = simulated;
    const SourceSettings st = g_settings[peer];
    src->flip = st.flip;
    if (settingsOut) *settingsOut = st;
    g_sources[src->id] = src;
    return src;
}

void ServeClient(SOCKET c, std::string peer) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    SourceSettings settings;
    auto src = AddSource(peer, false, &settings);
    if (!src) {
        std::fprintf(stderr, "[tcp] too many cameras, refusing %s\n", peer.c_str());
        closesocket(c);
        CoUninitialize();
        return;
    }
    src->sock = c;
    std::printf("[src %d] connected from %s\n", src->id, peer.c_str());
    H264Decoder dec;
    if (!dec.Init()) {
        RemoveSource(src);
        closesocket(c);
        CoUninitialize();
        return;
    }
    dec.onPicture = [src](std::shared_ptr<const Picture> p) {
        p = WithEffects(*src, std::move(p));
        {
            std::lock_guard<std::mutex> l(src->picMutex);
            src->latest = std::move(p);
        }
        MarkDirty();
    };
    SendOrientation(*src);  // a phone that connects later still gets the current settings
    SendResolution(*src, settings.resW, settings.resH);

    std::vector<BYTE> config, payload, unit;
    uint64_t bytes = 0, frames = 0, lastBytes = 0, lastFrames = 0, lastDecoded = 0;
    auto lastReport = std::chrono::steady_clock::now();
    uint32_t w = 0, h = 0;

    for (;;) {
        BYTE hdr[kHeaderLen];
        if (!RecvAll(c, hdr, kHeaderLen)) break;
        if (hdr[0] != 1) { std::fprintf(stderr, "[src %d] bad protocol version %u\n", src->id, hdr[0]); break; }
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
            const int old = src->rotation.exchange(rot);
            if (old != rot) std::printf("[src %d] rotation %d -> %u degrees\n", src->id, old, rot);
        }
        if (len > kMaxPayload) { std::fprintf(stderr, "[src %d] payload too large (%u)\n", src->id, len); break; }
        payload.resize(len);
        if (len && !RecvAll(c, payload.data(), len)) break;
        bytes += kHeaderLen + len;

        if (flags & kFlagConfig) {
            config = payload;
            w = pw; h = ph;
            std::printf("[src %d] stream %ux%u\n", src->id, w, h);
            continue;
        }
        if (type == 2) {  // control message from the phone
            if (!payload.empty() && payload[0] == 3) PrintCapabilities(src->id, payload);
            if (payload.size() > 1 && payload[0] == 4) {
                std::string name(payload.begin() + 1, payload.end());
                for (char& ch : name) if (ch == '\n' || ch == '\r') ch = ' ';
                std::printf("[src %d] name %s\n", src->id, name.c_str());
            }
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
            std::printf("[src %d] rx %.0f fps in, %.0f fps decoded, %.0f kbps, decode errors %llu\n", src->id,
                        (frames - lastFrames) / secs, (dec.decoded - lastDecoded) / secs,
                        (bytes - lastBytes) * 8 / 1000.0 / secs, static_cast<unsigned long long>(dec.errors));
            lastReport = now;
            lastBytes = bytes; lastFrames = frames; lastDecoded = dec.decoded;
        }
    }
    {
        std::lock_guard<std::mutex> l(src->sockMutex);
        src->sock = INVALID_SOCKET;
    }
    RemoveSource(src);
    closesocket(c);
    CoUninitialize();
}

// ---------- simulated cameras (development and demos: `--simulate N`) ----------
// Each one draws a moving test picture with its number, so layouts can be tried without phones.
// Even numbers are tall (portrait) pictures.

const char* const kDigitRows[10][7] = {
    {"01110", "10001", "10011", "10101", "11001", "10001", "01110"},
    {"00100", "01100", "00100", "00100", "00100", "00100", "01110"},
    {"01110", "10001", "00001", "00010", "00100", "01000", "11111"},
    {"11110", "00001", "00001", "01110", "00001", "00001", "11110"},
    {"00010", "00110", "01010", "10010", "11111", "00010", "00010"},
    {"11111", "10000", "11110", "00001", "00001", "10001", "01110"},
    {"00110", "01000", "10000", "11110", "10001", "10001", "01110"},
    {"11111", "00001", "00010", "00100", "01000", "01000", "01000"},
    {"01110", "10001", "10001", "01110", "10001", "10001", "01110"},
    {"01110", "10001", "10001", "01111", "00001", "00010", "01100"},
};

std::shared_ptr<Picture> MakeTestPicture(int w, int h, int number, double t) {
    auto pic = std::make_shared<Picture>();
    pic->w = static_cast<uint32_t>(w);
    pic->h = static_cast<uint32_t>(h);
    pic->nv12.resize(static_cast<size_t>(w) * h * 3 / 2);
    BYTE* y = pic->nv12.data();
    BYTE* uv = y + static_cast<size_t>(w) * h;
    static const BYTE palette[6][2] = {{110, 190}, {190, 110}, {70, 90}, {160, 60}, {90, 170}, {140, 150}};
    const BYTE* col = palette[(number - 1) % 6];
    const int shift = static_cast<int>(t * 90) % w;
    for (int j = 0; j < h; ++j) {
        for (int i = 0; i < w; ++i) y[static_cast<size_t>(j) * w + i] = static_cast<BYTE>(50 + 110 * ((i + shift) % w) / w + 30 * j / h);
    }
    for (int j = 0; j < h / 2; ++j) {
        for (int i = 0; i < w / 2; ++i) {
            uv[static_cast<size_t>(j) * w + i * 2] = col[0];
            uv[static_cast<size_t>(j) * w + i * 2 + 1] = col[1];
        }
    }
    // a white box sweeping across, and the camera number in the middle
    const int box = h / 7, bx = static_cast<int>((std::sin(t * 1.5) * 0.5 + 0.5) * (w - box)), by = h / 12;
    for (int j = by; j < by + box && j < h; ++j) memset(y + static_cast<size_t>(j) * w + bx, 235, std::min(box, w - bx));
    const int scale = std::max(2, h / 14);
    const int tx = (w - 5 * scale) / 2, ty = (h - 7 * scale) / 2;
    for (int r = 0; r < 7; ++r) {
        for (int cI = 0; cI < 5; ++cI) {
            if (kDigitRows[number % 10][r][cI] != '1') continue;
            for (int j = 0; j < scale; ++j) {
                const int yy = ty + r * scale + j;
                if (yy < 0 || yy >= h) continue;
                memset(y + static_cast<size_t>(yy) * w + tx + cI * scale, 240, scale);
            }
        }
    }
    return pic;
}

void RunSimulatedSource(std::shared_ptr<Source> src, int number) {
    const bool portrait = number % 2 == 0;
    std::printf("[src %d] connected from simulated\n", src->id);
    std::printf("[src %d] name Test camera %d\n", src->id, number);
    std::printf("[src %d] cap sizes=640x360,1280x720,1920x1080 current=1280x720 auto=1\n", src->id);
    std::printf("[src %d] stream 1280x720\n", src->id);
    const auto begin = std::chrono::steady_clock::now();
    auto lastReport = begin;
    int frames = 0;
    while (src->alive.load()) {
        const double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        std::shared_ptr<const Picture> pic = portrait ? MakeTestPicture(540, 960, number, t) : MakeTestPicture(1280, 720, number, t);
        pic = WithEffects(*src, std::move(pic));
        {
            std::lock_guard<std::mutex> l(src->picMutex);
            src->latest = pic;
        }
        MarkDirty();
        ++frames;
        if (std::chrono::steady_clock::now() - lastReport >= std::chrono::seconds(1)) {
            std::printf("[src %d] rx %d fps in, %d fps decoded, 0 kbps, decode errors 0\n", src->id, frames, frames);
            frames = 0;
            lastReport = std::chrono::steady_clock::now();
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(33));
    }
}

void AddSimulatedSources(int count) {
    for (int i = 0; i < count; ++i) {
        auto src = AddSource("simulated-" + std::to_string(g_nextSourceId), true, nullptr);
        if (!src) return;
        const int number = src->id;
        std::thread([src, number] { RunSimulatedSource(src, number); }).detach();
    }
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
//   quit                                       clean exit (withdraws the network announcement)
//   resolution <id> auto | <id> <w> <h>        picture size camera <id> captures
//   flip <id> <0|1>                            turn camera <id> by 180 degrees (upside-down mount)
//   disconnect <id>                            drop camera <id>
//   layout <n> {<id> <x> <y> <w> <h> <cover>}  the cells of the output frame: n cells, each with the
//                                              camera, a rectangle in fractions of the frame, and
//                                              cover (1) = fill and crop, (0) = fit the whole picture
//   simulate <n>                               add n test cameras (development)
// EOF is ignored on purpose: the receiver can also run with no console attached.
void WatchStdin() {
    char line[8192];
    while (std::fgets(line, sizeof(line), stdin)) {
        std::istringstream in(line);
        std::string cmd;
        in >> cmd;
        if (cmd == "quit") {
            std::printf("[mdns] withdrawing announcement\n");
            StopMdns();
            // Leave at once: running global clean-up while the matte threads and ONNX Runtime are alive can hang.
            std::fflush(stdout);
            TerminateProcess(GetCurrentProcess(), 0);
        } else if (cmd == "resolution") {
            int id = 0;
            std::string a;
            in >> id >> a;
            auto src = FindSource(id);
            if (!src) continue;
            int w = 0, h = 0;
            if (a != "auto") {
                w = std::atoi(a.c_str());
                in >> h;
                if (w <= 0 || h <= 0) continue;
            }
            {
                std::lock_guard<std::mutex> l(g_srcMutex);
                g_settings[src->peer].resW = w;
                g_settings[src->peer].resH = h;
            }
            std::printf("[ctl] resolution %d %d x %d\n", id, w, h);
            if (!src->simulated) SendResolution(*src, w, h);
        } else if (cmd == "flip") {
            int id = 0, on = 0;
            in >> id >> on;
            auto src = FindSource(id);
            if (!src) continue;
            src->flip = on != 0;
            {
                std::lock_guard<std::mutex> l(g_srcMutex);
                g_settings[src->peer].flip = on != 0;
            }
            std::printf("[ctl] flip %d %d\n", id, on ? 1 : 0);
            MarkDirty();
        } else if (cmd == "disconnect") {
            int id = 0;
            in >> id;
            auto src = FindSource(id);
            if (!src) continue;
            if (src->simulated) {
                RemoveSource(src);
            } else {
                std::lock_guard<std::mutex> l(src->sockMutex);
                if (src->sock != INVALID_SOCKET) shutdown(src->sock, SD_BOTH);  // the reader thread ends and cleans up
            }
        } else if (cmd == "layout") {
            int n = 0;
            in >> n;
            std::vector<Cell> cells;
            for (int i = 0; i < n && i < 32; ++i) {
                Cell c;
                int cover = 0;
                if (!(in >> c.src >> c.x >> c.y >> c.w >> c.h >> cover)) break;
                c.cover = cover != 0;
                cells.push_back(c);
            }
            {
                std::lock_guard<std::mutex> l(g_layoutMutex);
                g_cells = std::move(cells);
                g_layoutSet = true;
            }
            std::printf("[ctl] layout %zu cells\n", g_cells.size());
            MarkDirty();
        } else if (cmd == "effect") {
            // effect <id> <mode> <blur> <brightness> <contrast> <saturation> <warmth> <background file or ->
            int id = 0;
            auto st = std::make_shared<EffectSettings>();
            in >> id >> st->mode >> st->blur >> st->brightness >> st->contrast >> st->saturation >> st->warmth;
            std::string rest;
            std::getline(in, rest);
            while (!rest.empty() && (rest.front() == ' ' || rest.front() == '\t')) rest.erase(rest.begin());
            while (!rest.empty() && (rest.back() == '\n' || rest.back() == '\r' || rest.back() == ' ')) rest.pop_back();
            if (rest != "-" && !rest.empty()) {
                const int n = MultiByteToWideChar(CP_UTF8, 0, rest.c_str(), -1, nullptr, 0);
                if (n > 1) {
                    st->background.resize(static_cast<size_t>(n) - 1);
                    MultiByteToWideChar(CP_UTF8, 0, rest.c_str(), -1, st->background.data(), n);
                }
            }
            auto src = FindSource(id);
            if (!src) continue;
            st->mode = std::clamp(st->mode, 0, 2);
            st->blur = std::clamp(st->blur, 0, 100);
            st->brightness = std::clamp(st->brightness, -100, 100);
            st->contrast = std::clamp(st->contrast, -100, 100);
            st->saturation = std::clamp(st->saturation, -100, 100);
            st->warmth = std::clamp(st->warmth, -100, 100);
            {
                std::lock_guard<std::mutex> l(src->fxMutex);
                src->fxSettings = st;
            }
            std::printf("[ctl] effect %d mode %d\n", id, st->mode);
        } else if (cmd == "simulate") {
            int n = 0;
            in >> n;
            AddSimulatedSources(std::clamp(n, 0, 8));
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

// Loads a picture, applies the effects and writes the result as a bitmap (development check).
int RunFxTest(const std::wstring& in, const std::wstring& out, int mode, const std::wstring& bg) {
    int w = 0, h = 0;
    std::vector<BYTE> bgra;
    if (!fx::LoadImageBgra(in, &w, &h, &bgra)) { std::printf("cannot read %ls\n", in.c_str()); return 2; }
    auto pic = std::make_shared<Picture>();
    pic->w = static_cast<uint32_t>(w & ~1);
    pic->h = static_cast<uint32_t>(h & ~1);
    pic->nv12.resize(static_cast<size_t>(pic->w) * pic->h * 3 / 2);
    BYTE* Y = pic->nv12.data();
    BYTE* UV = Y + static_cast<size_t>(pic->w) * pic->h;
    for (uint32_t j = 0; j < pic->h; ++j) {
        for (uint32_t i = 0; i < pic->w; ++i) {
            const BYTE* p = &bgra[(static_cast<size_t>(j) * w + i) * 4];
            const int B = p[0], G = p[1], R = p[2];
            Y[static_cast<size_t>(j) * pic->w + i] = static_cast<BYTE>(((66 * R + 129 * G + 25 * B + 128) >> 8) + 16);
            if (((i | j) & 1) == 0) {
                BYTE* o = &UV[static_cast<size_t>(j / 2) * pic->w + i];
                o[0] = static_cast<BYTE>(((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128);
                o[1] = static_cast<BYTE>(((112 * R - 94 * G - 18 * B + 128) >> 8) + 128);
            }
        }
    }
    EffectSettings st;
    st.mode = mode;
    st.blur = 70;
    st.background = bg;
    if (mode == 3) { st.mode = 0; st.brightness = 10; st.contrast = 15; st.saturation = 25; st.warmth = 20; }
    fx::Processor proc;
    std::shared_ptr<const Picture> result;
    for (int i = 0; i < 6; ++i) {  // a few runs: the first one loads the background and warms up
        result = proc.Process(pic, 0, st);
        std::printf("run %d: %.1f ms\n", i, proc.lastMs);
    }
    SaveBmp(out.c_str(), result->nv12.data(), static_cast<int>(result->w), static_cast<int>(result->h));
    std::printf("wrote %ls (%ux%u)\n", out.c_str(), result->w, result->h);
    return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);  // logs are read from a redirected file while running
    int simulate = 0;
    std::wstring fxTestIn, fxTestOut, fxTestBg;
    int fxTestMode = 0;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::wstring(argv[i]) == L"--snap") g_snapPath = argv[i + 1];
        if (std::wstring(argv[i]) == L"--simulate") simulate = _wtoi(argv[i + 1]);
        if (std::wstring(argv[i]) == L"--port") kPort = static_cast<unsigned short>(_wtoi(argv[i + 1]));
        // --fx-test in.png out.bmp <0 none|1 blur|2 replace> [background.png]: run the effects on one picture
        if (std::wstring(argv[i]) == L"--fx-test" && i + 3 < argc) {
            fxTestIn = argv[i + 1];
            fxTestOut = argv[i + 2];
            fxTestMode = _wtoi(argv[i + 3]);
            if (i + 4 < argc) fxTestBg = argv[i + 4];
        }
    }
    for (int i = 1; i < argc; ++i) {
        if (std::wstring(argv[i]) == L"--no-discovery") g_noDiscovery = true;
    }
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);

    // Background effects: the model and onnxruntime.dll live next to this program.
    {
        wchar_t path[MAX_PATH];
        GetModuleFileNameW(nullptr, path, MAX_PATH);
        std::wstring dir(path);
        dir = dir.substr(0, dir.find_last_of(L'\\'));
        std::string why;
        if (fx::Init(dir, &why)) std::printf("[fx] background effects ready\n");
        else std::printf("[fx] background effects unavailable (%s)\n", why.c_str());
    }
    if (!fxTestIn.empty()) return RunFxTest(fxTestIn, fxTestOut, fxTestMode, fxTestBg);

    std::thread(PipeServer).detach();
    std::thread(PreviewPipeServer).detach();
    std::thread(CompositorLoop).detach();

    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(kPort);
    BOOL reuse = TRUE;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));
    if (bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(listener, 8) != 0) {
        std::fprintf(stderr, "Cannot listen on port %u (error %d). Is another receiver running?\n", kPort, WSAGetLastError());
        return 1;
    }
    std::printf("CamNexo receiver listening on TCP %u. Enter one of these in the phone app:\n", kPort);
    PrintAddresses();
    std::printf("  (USB: run `adb reverse tcp:%u tcp:%u`, then use 127.0.0.1)\n\n", kPort, kPort);
    if (!g_noDiscovery) StartMdns();
    std::thread(WatchStdin).detach();
    if (simulate > 0) AddSimulatedSources(std::min(simulate, 8));

    for (;;) {
        sockaddr_in peer{};
        int plen = sizeof(peer);
        SOCKET c = accept(listener, reinterpret_cast<sockaddr*>(&peer), &plen);
        if (c == INVALID_SOCKET) continue;
        BOOL nodelay = TRUE;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));
        char ip[64]{};
        inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
        // Every phone gets its own thread, decoder and place in the layout.
        std::thread(ServeClient, c, std::string(ip)).detach();
    }
}
