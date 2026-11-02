// CamNexo desktop receiver for Linux.
//   TCP :7878  <- phones (CamNexo protocol v1, H.264 Annex B), up to 8 at once
//   FFmpeg (libavcodec) H.264 decoder -> NV12 pictures -> effects -> layout compositor
//   -> /dev/videoN made by v4l2loopback (the virtual camera "CamNexo")
//   -> a Unix socket with small RGBA frames for the preview in the desktop window
//
// It speaks the same stdin commands and prints the same log lines as the Windows receiver
// (native/windows/vcam/src/receiver_main.cpp), so the desktop app drives both the same way.
// The picture code (draw.cpp) and the effects (effects.cpp) are shared with the Windows build.

#include <arpa/inet.h>
#include <avahi-client/client.h>
#include <avahi-client/publish.h>
#include <avahi-common/alternative.h>
#include <avahi-common/error.h>
#include <avahi-common/malloc.h>
#include <avahi-common/thread-watch.h>
#include <dirent.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/videodev2.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
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

namespace {

unsigned short kPort = 7878;  // --port N changes it (development)
bool g_noDiscovery = false;   // --no-discovery: do not announce on the network
bool g_noV4l2 = false;        // --no-v4l2: do not write to a virtual camera (development, tests)
std::string g_v4l2Path;       // --device /dev/videoN: skip the search for the CamNexo camera
std::string g_previewPath;    // where the preview socket lives
uint32_t g_outW = 1920, g_outH = 1080;  // size of the pictures written to the virtual camera
constexpr size_t kHeaderLen = 28;
constexpr uint32_t kMaxPayload = 16 * 1024 * 1024;
constexpr uint8_t kFlagConfig = 1;

// ---------- latest composed frame, shared with the camera and preview writers ----------

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

struct SourceSettings {
    int resW = 0;  // 0 = Auto
    int resH = 0;
    bool flip = false;
};

struct Source {
    int id = 0;
    std::string peer;
    bool simulated = false;
    std::atomic<int> rotation{0};
    std::atomic<bool> flip{false};
    std::atomic<bool> alive{true};
    int sock = -1;
    std::mutex sockMutex;
    std::mutex picMutex;
    std::shared_ptr<const Picture> latest;

    std::mutex fxMutex;
    std::shared_ptr<const EffectSettings> fxSettings;
    fx::Processor fxProc;
    int fxLogCounter = 0;
    double fxMsSum = 0;
};

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
        if (++s.fxLogCounter >= 150) {
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

struct Cell {
    int src = -1;
    double x = 0, y = 0, w = 1, h = 1;
    bool cover = false;
};

std::mutex g_layoutMutex;
std::vector<Cell> g_cells;
bool g_layoutSet = false;

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

// `camnexo_receiver --snap frame.bmp` rewrites the file with the latest frame about every 2 seconds.
std::string g_snapPath;

inline BYTE Clamp8(int v) { return static_cast<BYTE>(v < 0 ? 0 : v > 255 ? 255 : v); }

void SaveBmp(const char* path, const BYTE* nv12, int w, int h) {
    const size_t stride = (static_cast<size_t>(w) * 3 + 3) & ~static_cast<size_t>(3);
    std::vector<BYTE> rgb(stride * h);
    const BYTE* uv = nv12 + static_cast<size_t>(w) * h;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const int Y = nv12[y * w + x] - 16;
            const int U = uv[(y / 2) * w + (x / 2) * 2] - 128;
            const int V = uv[(y / 2) * w + (x / 2) * 2 + 1] - 128;
            const int c = 298 * Y;
            BYTE* p = &rgb[static_cast<size_t>(h - 1 - y) * stride + static_cast<size_t>(x) * 3];
            p[0] = Clamp8((c + 516 * U + 128) >> 8);
            p[1] = Clamp8((c - 100 * U - 208 * V + 128) >> 8);
            p[2] = Clamp8((c + 409 * V + 128) >> 8);
        }
    }
    auto put16 = [](BYTE* p, uint16_t v) { p[0] = v & 255; p[1] = v >> 8; };
    auto put32 = [](BYTE* p, uint32_t v) { for (int i = 0; i < 4; ++i) p[i] = (v >> (8 * i)) & 255; };
    BYTE head[54] = {};
    head[0] = 'B';
    head[1] = 'M';
    put32(head + 2, static_cast<uint32_t>(54 + rgb.size()));
    put32(head + 10, 54);
    put32(head + 14, 40);
    put32(head + 18, static_cast<uint32_t>(w));
    put32(head + 22, static_cast<uint32_t>(h));
    put16(head + 26, 1);
    put16(head + 28, 24);
    FILE* f = std::fopen(path, "wb");
    if (!f) return;
    std::fwrite(head, 1, sizeof(head), f);
    std::fwrite(rgb.data(), 1, rgb.size(), f);
    std::fclose(f);
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

// ---------- preview socket (small RGBA frames for the desktop window) ----------

bool SendAll(int fd, const void* data, size_t len) {
    const BYTE* p = static_cast<const BYTE*>(data);
    while (len) {
        const ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n <= 0) return false;
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

void PreviewClient(int fd) {
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
        for (uint32_t y = 0; y < kPreviewHeight; ++y) {
            const uint32_t sy = y * h / kPreviewHeight;
            for (uint32_t x = 0; x < kPreviewWidth; ++x) {
                const uint32_t sx = x * w / kPreviewWidth;
                const int Y = local[static_cast<size_t>(sy) * w + sx] - 16;
                const BYTE* px = uv + static_cast<size_t>(sy / 2) * w + (sx & ~1u);
                const int U = px[0] - 128, V = px[1] - 128;
                const int c = 298 * Y;
                *o++ = Clamp8((c + 409 * V + 128) >> 8);
                *o++ = Clamp8((c - 100 * U - 208 * V + 128) >> 8);
                *o++ = Clamp8((c + 516 * U + 128) >> 8);
                *o++ = 255;
            }
        }
        if (!SendAll(fd, &hdr, sizeof(hdr)) || !SendAll(fd, rgba.data(), rgba.size())) break;
    }
    close(fd);
}

std::string DefaultPreviewPath() {
    const char* run = std::getenv("XDG_RUNTIME_DIR");
    if (run && *run) return std::string(run) + "/camnexo-preview.sock";
    return "/tmp/camnexo-" + std::to_string(static_cast<unsigned>(getuid())) + "-preview.sock";
}

void PreviewServer() {
    const int srv = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (srv < 0) {
        std::fprintf(stderr, "[preview] socket failed (%d)\n", errno);
        return;
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (g_previewPath.size() >= sizeof(addr.sun_path)) {
        std::fprintf(stderr, "[preview] socket path too long\n");
        close(srv);
        return;
    }
    std::strncpy(addr.sun_path, g_previewPath.c_str(), sizeof(addr.sun_path) - 1);
    unlink(g_previewPath.c_str());
    if (bind(srv, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(srv, 4) != 0) {
        std::fprintf(stderr, "[preview] cannot listen on %s (%d)\n", g_previewPath.c_str(), errno);
        close(srv);
        return;
    }
    chmod(g_previewPath.c_str(), 0600);  // only this user
    for (;;) {
        const int c = accept4(srv, nullptr, nullptr, SOCK_CLOEXEC);
        if (c < 0) continue;
        std::thread(PreviewClient, c).detach();
    }
}

// ---------- the virtual camera (v4l2loopback) ----------

// Finds the loopback device the module was loaded for: its card label is "CamNexo".
std::string FindCamNexoDevice() {
    if (!g_v4l2Path.empty()) return g_v4l2Path;
    DIR* d = opendir("/sys/class/video4linux");
    if (!d) return "";
    std::string found;
    while (dirent* e = readdir(d)) {
        if (std::strncmp(e->d_name, "video", 5) != 0) continue;
        std::ifstream in(std::string("/sys/class/video4linux/") + e->d_name + "/name");
        std::string name;
        std::getline(in, name);
        if (name == "CamNexo") {
            found = std::string("/dev/") + e->d_name;
            break;
        }
    }
    closedir(d);
    return found;
}

// Writes the NV12 picture (already the output size) as YUYV, the format every video app understands.
void NV12ToYuyv(const BYTE* nv12, uint32_t w, uint32_t h, std::vector<BYTE>& out) {
    out.resize(static_cast<size_t>(w) * h * 2);
    const BYTE* uv = nv12 + static_cast<size_t>(w) * h;
    for (uint32_t y = 0; y < h; ++y) {
        const BYTE* yr = nv12 + static_cast<size_t>(y) * w;
        const BYTE* ur = uv + static_cast<size_t>(y / 2) * w;
        BYTE* o = &out[static_cast<size_t>(y) * w * 2];
        for (uint32_t x = 0; x < w; x += 2) {
            o[0] = yr[x];
            o[1] = ur[x];
            o[2] = yr[x + 1];
            o[3] = ur[x + 1];
            o += 4;
        }
    }
}

// The composed canvas follows the phone's picture; the camera has one fixed size, so it is fitted
// into the output size with black bars.
void FitToOutput(const std::vector<BYTE>& nv12, uint32_t w, uint32_t h, std::vector<BYTE>& out) {
    const size_t ySize = static_cast<size_t>(g_outW) * g_outH;
    out.assign(ySize * 3 / 2, 128);
    std::memset(out.data(), 16, ySize);
    if (w < 2 || h < 2 || nv12.size() < static_cast<size_t>(w) * h * 3 / 2) return;
    if (w == g_outW && h == g_outH) {
        std::memcpy(out.data(), nv12.data(), out.size());
        return;
    }
    Picture p;
    p.w = w;
    p.h = h;
    p.upright = true;
    p.nv12 = nv12;
    DrawCell(p, 0, false, out.data(), out.data() + ySize, static_cast<int>(g_outW), 0, 0, static_cast<int>(g_outW),
             static_cast<int>(g_outH));
}

// Opens the device and sets the output format. Returns the descriptor, or -1 with `*err` set to the reason.
int OpenCamera(const std::string& path, int* err) {
    const int fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        *err = errno;
        return -1;
    }
    v4l2_format fmt{};
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = g_outW;
    fmt.fmt.pix.height = g_outH;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    fmt.fmt.pix.bytesperline = g_outW * 2;
    fmt.fmt.pix.sizeimage = g_outW * g_outH * 2;
    fmt.fmt.pix.colorspace = V4L2_COLORSPACE_REC709;
    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        *err = errno;
        close(fd);
        return -1;
    }
    return fd;
}

void CameraLoop() {
    int fd = -1;
    std::string path;
    std::string said;  // the last problem reported, so a repeating one is printed once
    uint64_t lastSeq = 0;
    std::vector<BYTE> local, fitted, yuyv;
    uint32_t w = 0, h = 0;
    for (;;) {
        if (fd < 0) {
            path = FindCamNexoDevice();
            int err = 0;
            if (!path.empty()) fd = OpenCamera(path, &err);
            if (fd < 0) {
                std::string problem;
                if (path.empty()) {
                    problem = "[v4l2] no CamNexo camera found (load the v4l2loopback module with card_label=CamNexo)";
                } else {
                    problem = "[v4l2] cannot open " + path + ": " + std::strerror(err) +
                              (err == EACCES ? " (your user needs access to video devices: add it to the video group, then log in again)" : "");
                }
                if (problem != said) {
                    std::printf("%s\n", problem.c_str());
                    said = problem;
                }
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
            said.clear();
            std::printf("[v4l2] ready %s (%ux%u)\n", path.c_str(), g_outW, g_outH);
            lastSeq = 0;
        }
        bool fresh = false;
        {
            std::unique_lock<std::mutex> lk(g_bus.m);
            fresh = g_bus.cv.wait_for(lk, std::chrono::milliseconds(200), [&] { return g_bus.seq != lastSeq; });
            if (fresh) {
                local = g_bus.nv12;
                w = g_bus.w;
                h = g_bus.h;
                lastSeq = g_bus.seq;
            }
        }
        if (fresh) {
            FitToOutput(local, w, h, fitted);
        } else if (fitted.empty()) {
            FitToOutput({}, 0, 0, fitted);  // nothing yet: black, so apps that open the camera see a picture
        }
        // Not fresh: the last picture again, so the stream never stalls while nothing changes.
        NV12ToYuyv(fitted.data(), g_outW, g_outH, yuyv);
        const BYTE* p = yuyv.data();
        size_t left = yuyv.size();
        bool failed = false;
        while (left) {
            const ssize_t n = write(fd, p, left);
            if (n <= 0) {
                failed = true;
                break;
            }
            p += n;
            left -= static_cast<size_t>(n);
        }
        if (failed) {
            std::printf("[v4l2] lost %s (%d)\n", path.c_str(), errno);
            close(fd);
            fd = -1;
        } else if (!fresh) {
            std::this_thread::sleep_for(std::chrono::milliseconds(150));
        }
    }
}

// ---------- H.264 decoding (FFmpeg) ----------

class H264Decoder {
public:
    ~H264Decoder() {
        if (_frame) av_frame_free(&_frame);
        if (_pkt) av_packet_free(&_pkt);
        if (_ctx) avcodec_free_context(&_ctx);
    }

    bool Init() {
        const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
        if (!codec) {
            std::fprintf(stderr, "[dec] FFmpeg has no H.264 decoder\n");
            return false;
        }
        _ctx = avcodec_alloc_context3(codec);
        if (!_ctx) return false;
        _ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        _ctx->flags2 |= AV_CODEC_FLAG2_FAST;
        _ctx->thread_count = 2;
        _ctx->thread_type = FF_THREAD_SLICE;  // no frame threads: they add whole frames of delay
        if (avcodec_open2(_ctx, codec, nullptr) < 0) {
            std::fprintf(stderr, "[dec] cannot open the H.264 decoder\n");
            return false;
        }
        _pkt = av_packet_alloc();
        _frame = av_frame_alloc();
        return _pkt && _frame;
    }

    // Feeds one Annex B access unit and publishes every picture the decoder yields.
    void Decode(const BYTE* data, size_t len, uint64_t ts100ns) {
        _buf.assign(len + AV_INPUT_BUFFER_PADDING_SIZE, 0);
        std::memcpy(_buf.data(), data, len);
        _pkt->data = _buf.data();
        _pkt->size = static_cast<int>(len);
        _pkt->pts = static_cast<int64_t>(ts100ns);
        if (avcodec_send_packet(_ctx, _pkt) < 0) {
            ++errors;
            return;
        }
        while (avcodec_receive_frame(_ctx, _frame) == 0) {
            Emit(*_frame);
            av_frame_unref(_frame);
        }
    }

    uint64_t decoded = 0;
    uint64_t errors = 0;
    std::function<void(std::shared_ptr<const Picture>)> onPicture;

private:
    // Copies the picture into a tightly packed NV12 Picture. Placing it on the canvas (rotation, fit or
    // crop) is the compositor's job.
    void Emit(const AVFrame& f) {
        ++decoded;
        if (!onPicture || f.width < 2 || f.height < 2) return;
        const bool planar = f.format == AV_PIX_FMT_YUV420P || f.format == AV_PIX_FMT_YUVJ420P;
        const bool semi = f.format == AV_PIX_FMT_NV12;
        if (!planar && !semi) {
            ++errors;
            return;
        }
        auto pic = std::make_shared<Picture>();
        pic->w = static_cast<uint32_t>(f.width) & ~1u;
        pic->h = static_cast<uint32_t>(f.height) & ~1u;
        pic->ts100ns = static_cast<uint64_t>(f.pts < 0 ? 0 : f.pts);
        pic->nv12.resize(static_cast<size_t>(pic->w) * pic->h * 3 / 2);
        BYTE* dst = pic->nv12.data();
        for (uint32_t y = 0; y < pic->h; ++y) std::memcpy(dst + static_cast<size_t>(y) * pic->w, f.data[0] + static_cast<size_t>(y) * f.linesize[0], pic->w);
        BYTE* dstUv = dst + static_cast<size_t>(pic->w) * pic->h;
        for (uint32_t y = 0; y < pic->h / 2; ++y) {
            BYTE* row = dstUv + static_cast<size_t>(y) * pic->w;
            if (semi) {
                std::memcpy(row, f.data[1] + static_cast<size_t>(y) * f.linesize[1], pic->w);
            } else {
                const BYTE* u = f.data[1] + static_cast<size_t>(y) * f.linesize[1];
                const BYTE* v = f.data[2] + static_cast<size_t>(y) * f.linesize[2];
                for (uint32_t x = 0; x < pic->w / 2; ++x) {
                    row[x * 2] = u[x];
                    row[x * 2 + 1] = v[x];
                }
            }
        }
        onPicture(std::move(pic));
    }

    AVCodecContext* _ctx = nullptr;
    AVPacket* _pkt = nullptr;
    AVFrame* _frame = nullptr;
    std::vector<BYTE> _buf;
};

// ---------- compositor ----------

constexpr uint32_t kMaxCanvasH = 2160;
constexpr uint32_t kMaxCanvasW = 3840;

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

    int canvasH = 1080;
    if (cellsWithCamera == 1) {
        canvasH = static_cast<int>(std::min<uint32_t>(kMaxCanvasH, std::min(items[0].pic->w, items[0].pic->h)));
    }
    canvasH = std::max(canvasH & ~1, 2);
    int canvasW = static_cast<int>(std::min<uint32_t>(kMaxCanvasW, static_cast<uint32_t>(canvasH) * 16 / 9)) & ~1;
    outW = canvasW;
    outH = canvasH;
    const size_t ySize = static_cast<size_t>(canvasW) * canvasH;
    out.resize(ySize * 3 / 2);
    std::memset(out.data(), 16, ySize);
    std::memset(out.data() + ySize, 128, ySize / 2);

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
            const uint64_t ts = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(last.time_since_epoch()).count() / 100);
            Publish(frame.data(), static_cast<uint32_t>(w), static_cast<uint32_t>(h), ts);
        }
    }
}

// ---------- control (desktop app -> phone) ----------
// Same packets as the Windows receiver; see docs/PROTOCOL.md.

bool RecvAll(int s, void* buf, size_t len) {
    BYTE* p = static_cast<BYTE*>(buf);
    while (len) {
        const ssize_t n = recv(s, p, len > (1 << 20) ? (1 << 20) : len, 0);
        if (n <= 0) return false;
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

void SendControl(Source& s, const BYTE* payload, uint32_t len) {
    std::lock_guard<std::mutex> l(s.sockMutex);
    if (s.sock < 0) return;
    std::vector<BYTE> pkt(kHeaderLen + len, 0);
    pkt[0] = 1;  // protocol version
    pkt[1] = 2;  // packet type: control
    std::memcpy(pkt.data() + 20, &len, sizeof(len));
    std::memcpy(pkt.data() + kHeaderLen, payload, len);
    send(s.sock, pkt.data(), pkt.size(), MSG_NOSIGNAL);
}

void SendOrientation(Source& s) {
    const BYTE p[3] = {1, 0, 0};
    SendControl(s, p, sizeof(p));
}

void SendResolution(Source& s, int w, int h) {
    const uint16_t pw = static_cast<uint16_t>(w), ph = static_cast<uint16_t>(h);
    BYTE p[5] = {2};
    std::memcpy(p + 1, &pw, 2);
    std::memcpy(p + 3, &ph, 2);
    SendControl(s, p, sizeof(p));
}

void PrintCapabilities(int id, const std::vector<BYTE>& p) {
    if (p.size() < 2) return;
    const size_t count = p[1];
    if (p.size() < 2 + count * 4 + 5) return;
    std::string sizes;
    for (size_t i = 0; i < count; ++i) {
        uint16_t w, h;
        std::memcpy(&w, p.data() + 2 + i * 4, 2);
        std::memcpy(&h, p.data() + 2 + i * 4 + 2, 2);
        if (!sizes.empty()) sizes += ',';
        sizes += std::to_string(w) + "x" + std::to_string(h);
    }
    uint16_t cw, ch;
    std::memcpy(&cw, p.data() + 2 + count * 4, 2);
    std::memcpy(&ch, p.data() + 2 + count * 4 + 2, 2);
    const int autoMode = p[2 + count * 4 + 4];
    std::printf("[src %d] cap sizes=%s current=%ux%u auto=%d\n", id, sizes.c_str(), cw, ch, autoMode);
}

void RemoveSource(const std::shared_ptr<Source>& src) {
    src->alive = false;
    {
        std::lock_guard<std::mutex> l(g_srcMutex);
        g_sources.erase(src->id);
    }
    std::printf("[src %d] disconnected\n", src->id);
    MarkDirty();
}

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

void ServeClient(int c, std::string peer) {
    SourceSettings settings;
    auto src = AddSource(peer, false, &settings);
    if (!src) {
        std::fprintf(stderr, "[tcp] too many cameras, refusing %s\n", peer.c_str());
        close(c);
        return;
    }
    src->sock = c;
    std::printf("[src %d] connected from %s\n", src->id, peer.c_str());
    H264Decoder dec;
    if (!dec.Init()) {
        RemoveSource(src);
        close(c);
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
    SendOrientation(*src);
    SendResolution(*src, settings.resW, settings.resH);

    std::vector<BYTE> config, payload, unit;
    uint64_t bytes = 0, frames = 0, lastBytes = 0, lastFrames = 0, lastDecoded = 0;
    auto lastReport = std::chrono::steady_clock::now();
    uint32_t w = 0, h = 0;

    for (;;) {
        BYTE hdr[kHeaderLen];
        if (!RecvAll(c, hdr, kHeaderLen)) break;
        if (hdr[0] != 1) {
            std::fprintf(stderr, "[src %d] bad protocol version %u\n", src->id, hdr[0]);
            break;
        }
        const uint8_t type = hdr[1], flags = hdr[3];
        uint64_t ptsUs;
        uint32_t len;
        std::memcpy(&ptsUs, hdr + 8, 8);
        std::memcpy(&len, hdr + 20, 4);
        uint16_t pw, ph, rot;
        std::memcpy(&pw, hdr + 16, 2);
        std::memcpy(&ph, hdr + 18, 2);
        std::memcpy(&rot, hdr + 24, 2);
        if (type != 2) {
            const int old = src->rotation.exchange(rot);
            if (old != rot) std::printf("[src %d] rotation %d -> %u degrees\n", src->id, old, rot);
        }
        if (len > kMaxPayload) {
            std::fprintf(stderr, "[src %d] payload too large (%u)\n", src->id, len);
            break;
        }
        payload.resize(len);
        if (len && !RecvAll(c, payload.data(), len)) break;
        bytes += kHeaderLen + len;

        if (flags & kFlagConfig) {
            config = payload;
            w = pw;
            h = ph;
            std::printf("[src %d] stream %ux%u\n", src->id, w, h);
            continue;
        }
        if (type == 2) {
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
            lastBytes = bytes;
            lastFrames = frames;
            lastDecoded = dec.decoded;
        }
    }
    {
        std::lock_guard<std::mutex> l(src->sockMutex);
        src->sock = -1;
    }
    RemoveSource(src);
    close(c);
}

// ---------- simulated cameras (development and demos: `--simulate N`) ----------

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
    const int box = h / 7, bx = static_cast<int>((std::sin(t * 1.5) * 0.5 + 0.5) * (w - box)), by = h / 12;
    for (int j = by; j < by + box && j < h; ++j) std::memset(y + static_cast<size_t>(j) * w + bx, 235, std::min(box, w - bx));
    const int scale = std::max(2, h / 14);
    const int tx = (w - 5 * scale) / 2, ty = (h - 7 * scale) / 2;
    for (int r = 0; r < 7; ++r) {
        for (int cI = 0; cI < 5; ++cI) {
            if (kDigitRows[number % 10][r][cI] != '1') continue;
            for (int j = 0; j < scale; ++j) {
                const int yy = ty + r * scale + j;
                if (yy < 0 || yy >= h) continue;
                std::memset(y + static_cast<size_t>(yy) * w + tx + cI * scale, 240, scale);
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

// ---------- mDNS / DNS-SD announcement (_camnexo._tcp), through the Avahi daemon ----------

AvahiThreadedPoll* g_avahiPoll = nullptr;
AvahiClient* g_avahi = nullptr;
AvahiEntryGroup* g_avahiGroup = nullptr;
char* g_avahiName = nullptr;
std::string g_hostSafe;

void CreateServices(AvahiClient* c);

void GroupCallback(AvahiEntryGroup* g, AvahiEntryGroupState state, void*) {
    switch (state) {
        case AVAHI_ENTRY_GROUP_ESTABLISHED:
            std::printf("[mdns] registered as %s\n", g_avahiName);
            break;
        case AVAHI_ENTRY_GROUP_COLLISION: {
            // An older announcement of the same name is still around: take another name.
            char* alt = avahi_alternative_service_name(g_avahiName);
            avahi_free(g_avahiName);
            g_avahiName = alt;
            CreateServices(avahi_entry_group_get_client(g));
            break;
        }
        case AVAHI_ENTRY_GROUP_FAILURE:
            std::printf("[mdns] registration FAILED (%s)\n", avahi_strerror(avahi_client_errno(avahi_entry_group_get_client(g))));
            break;
        default:
            break;
    }
}

void CreateServices(AvahiClient* c) {
    if (!g_avahiGroup) g_avahiGroup = avahi_entry_group_new(c, GroupCallback, nullptr);
    if (!g_avahiGroup) {
        std::printf("[mdns] registration FAILED (%s)\n", avahi_strerror(avahi_client_errno(c)));
        return;
    }
    if (!avahi_entry_group_is_empty(g_avahiGroup)) return;
    AvahiStringList* txt = avahi_string_list_new("v=1", nullptr);
    txt = avahi_string_list_add_printf(txt, "name=%s", g_hostSafe.c_str());
    const int r = avahi_entry_group_add_service_strlst(g_avahiGroup, AVAHI_IF_UNSPEC, AVAHI_PROTO_UNSPEC, static_cast<AvahiPublishFlags>(0),
                                                       g_avahiName, "_camnexo._tcp", nullptr, nullptr, kPort, txt);
    avahi_string_list_free(txt);
    if (r == AVAHI_ERR_COLLISION) {
        char* alt = avahi_alternative_service_name(g_avahiName);
        avahi_free(g_avahiName);
        g_avahiName = alt;
        avahi_entry_group_reset(g_avahiGroup);
        CreateServices(c);
        return;
    }
    if (r < 0 || avahi_entry_group_commit(g_avahiGroup) < 0) {
        std::printf("[mdns] registration FAILED (%s)\n", avahi_strerror(r < 0 ? r : avahi_client_errno(c)));
    }
}

void ClientCallback(AvahiClient* c, AvahiClientState state, void*) {
    switch (state) {
        case AVAHI_CLIENT_S_RUNNING:
            CreateServices(c);
            break;
        case AVAHI_CLIENT_FAILURE:
            std::printf("[mdns] registration FAILED (%s)\n", avahi_strerror(avahi_client_errno(c)));
            break;
        case AVAHI_CLIENT_S_COLLISION:
        case AVAHI_CLIENT_S_REGISTERING:
            if (g_avahiGroup) avahi_entry_group_reset(g_avahiGroup);
            break;
        default:
            break;
    }
}

void StartMdns() {
    char host[256]{};
    gethostname(host, sizeof(host) - 1);
    for (const char* p = host; *p && *p != '.'; ++p) g_hostSafe += (std::isalnum(static_cast<unsigned char>(*p)) || *p == '-') ? *p : '-';
    if (g_hostSafe.empty()) g_hostSafe = "computer";
    g_avahiName = avahi_strdup(("CamNexo-" + g_hostSafe).c_str());
    g_avahiPoll = avahi_threaded_poll_new();
    if (!g_avahiPoll) {
        std::printf("[mdns] registration FAILED (no event loop)\n");
        return;
    }
    int err = 0;
    g_avahi = avahi_client_new(avahi_threaded_poll_get(g_avahiPoll), static_cast<AvahiClientFlags>(0), ClientCallback, nullptr, &err);
    if (!g_avahi) {
        std::printf("[mdns] registration FAILED (%s; is avahi-daemon running?)\n", avahi_strerror(err));
        return;
    }
    avahi_threaded_poll_start(g_avahiPoll);
}

void StopMdns() {
    if (g_avahiPoll) avahi_threaded_poll_stop(g_avahiPoll);  // the client's goodbye tells phones at once
    if (g_avahi) avahi_client_free(g_avahi);
    g_avahi = nullptr;
}

// ---------- effects files ----------

bool FileExists(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// Background effects need libonnxruntime.so and the model. They are not part of the package: the desktop
// app downloads them into ~/.local/share/camnexo/effects on first use. A copy next to this program
// (a development build) is used first.
void InitEffects() {
    if (fx::Available()) {
        std::printf("[fx] background effects ready\n");
        return;
    }
    std::vector<std::string> dirs;
    char exe[4096]{};
    const ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n > 0) {
        std::string e(exe, static_cast<size_t>(n));
        dirs.push_back(e.substr(0, e.find_last_of('/')));
    }
    const char* data = std::getenv("XDG_DATA_HOME");
    const char* home = std::getenv("HOME");
    if (data && *data) dirs.push_back(std::string(data) + "/camnexo/effects");
    else if (home && *home) dirs.push_back(std::string(home) + "/.local/share/camnexo/effects");

    std::string why = "not installed";
    for (const auto& dir : dirs) {
        if (!FileExists(dir + "/libonnxruntime.so") || !FileExists(dir + "/models/modnet.onnx")) continue;
        std::string err;
        if (fx::Init(dir, &err)) {
            std::printf("[fx] background effects ready\n");
            return;
        }
        why = err;
    }
    std::printf("[fx] background effects unavailable (%s)\n", why.c_str());
}

// ---------- stdin commands from the desktop app ----------
//   quit                                       clean exit (withdraws the network announcement)
//   resolution <id> auto | <id> <w> <h>        picture size camera <id> captures
//   flip <id> <0|1>                            turn camera <id> by 180 degrees (upside-down mount)
//   disconnect <id>                            drop camera <id>
//   layout <n> {<id> <x> <y> <w> <h> <cover>}  the cells of the output frame
//   effect <id> <mode> <blur> <bright> <contrast> <sat> <warm> <background file or ->
//   fxinit                                     look again for the effects files (after they were downloaded)
//   simulate <n>                               add n test cameras (development)

void WatchStdin() {
    char line[8192];
    while (std::fgets(line, sizeof(line), stdin)) {
        std::istringstream in(line);
        std::string cmd;
        in >> cmd;
        if (cmd == "quit") {
            std::printf("[mdns] withdrawing announcement\n");
            StopMdns();
            std::fflush(stdout);
            if (!g_previewPath.empty()) unlink(g_previewPath.c_str());
            _exit(0);  // leave at once: global clean-up with the matte threads alive can hang
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
                if (src->sock >= 0) shutdown(src->sock, SHUT_RDWR);  // the reader thread ends and cleans up
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
            int id = 0;
            auto st = std::make_shared<EffectSettings>();
            in >> id >> st->mode >> st->blur >> st->brightness >> st->contrast >> st->saturation >> st->warmth;
            std::string rest;
            std::getline(in, rest);
            while (!rest.empty() && (rest.front() == ' ' || rest.front() == '\t')) rest.erase(rest.begin());
            while (!rest.empty() && (rest.back() == '\n' || rest.back() == '\r' || rest.back() == ' ')) rest.pop_back();
            if (rest != "-" && !rest.empty()) st->background = rest;
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
        } else if (cmd == "fxinit") {
            InitEffects();
        } else if (cmd == "simulate") {
            int n = 0;
            in >> n;
            AddSimulatedSources(std::clamp(n, 0, 8));
        }
    }
}

void PrintAddresses() {
    ifaddrs* list = nullptr;
    if (getifaddrs(&list) != 0) return;
    for (ifaddrs* a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET || (a->ifa_flags & IFF_LOOPBACK) || !(a->ifa_flags & IFF_UP)) continue;
        char ip[64]{};
        inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(a->ifa_addr)->sin_addr, ip, sizeof(ip));
        std::printf("  phone address:  %s:%u\n", ip, kPort);
    }
    freeifaddrs(list);
}

// `--fx-test in.png out.bmp <0 none|1 blur|2 replace|3 filters> [background.png]`: run the effects on one picture.
int RunFxTest(const std::string& in, const std::string& out, int mode, const std::string& bg) {
    int w = 0, h = 0;
    std::vector<BYTE> bgra;
    if (!fx::LoadImageBgra(in, &w, &h, &bgra)) {
        std::printf("cannot read %s\n", in.c_str());
        return 2;
    }
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
            Y[static_cast<size_t>(j) * pic->w + i] = Clamp8(((66 * R + 129 * G + 25 * B + 128) >> 8) + 16);
            if (((i | j) & 1) == 0) {
                BYTE* o = &UV[static_cast<size_t>(j / 2) * pic->w + i];
                o[0] = Clamp8(((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128);
                o[1] = Clamp8(((112 * R - 94 * G - 18 * B + 128) >> 8) + 128);
            }
        }
    }
    EffectSettings st;
    st.mode = mode;
    st.blur = 70;
    st.background = bg;
    if (mode == 3) {
        st.mode = 0;
        st.brightness = 10;
        st.contrast = 15;
        st.saturation = 25;
        st.warmth = 20;
    }
    fx::Processor proc;
    std::shared_ptr<const Picture> result;
    for (int i = 0; i < 6; ++i) {
        result = proc.Process(pic, 0, st);
        std::printf("run %d: %.1f ms\n", i, proc.lastMs);
    }
    SaveBmp(out.c_str(), result->nv12.data(), static_cast<int>(result->w), static_cast<int>(result->h));
    std::printf("wrote %s (%ux%u)\n", out.c_str(), result->w, result->h);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);  // logs are read through a pipe while running
    signal(SIGPIPE, SIG_IGN);
    int simulate = 0;
    std::string fxIn, fxOut, fxBg;
    int fxMode = 0;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        const bool more = i + 1 < argc;
        if (a == "--no-discovery") g_noDiscovery = true;
        else if (a == "--no-v4l2") g_noV4l2 = true;
        else if (a == "--snap" && more) g_snapPath = argv[++i];
        else if (a == "--simulate" && more) simulate = std::atoi(argv[++i]);
        else if (a == "--port" && more) kPort = static_cast<unsigned short>(std::atoi(argv[++i]));
        else if (a == "--device" && more) g_v4l2Path = argv[++i];
        else if (a == "--preview-socket" && more) g_previewPath = argv[++i];
        else if (a == "--out" && more) {
            unsigned w = 0, h = 0;
            if (std::sscanf(argv[++i], "%ux%u", &w, &h) == 2 && w >= 2 && h >= 2 && w <= 3840 && h <= 2160) {
                g_outW = w & ~1u;
                g_outH = h & ~1u;
            }
        } else if (a == "--fx-test" && i + 3 < argc) {
            fxIn = argv[i + 1];
            fxOut = argv[i + 2];
            fxMode = std::atoi(argv[i + 3]);
            i += 3;
            if (i + 1 < argc && std::strncmp(argv[i + 1], "--", 2) != 0) fxBg = argv[++i];
        }
    }
    if (g_previewPath.empty()) g_previewPath = DefaultPreviewPath();

    InitEffects();
    if (!fxIn.empty()) return RunFxTest(fxIn, fxOut, fxMode, fxBg);

    std::thread(PreviewServer).detach();
    std::thread(CompositorLoop).detach();
    if (!g_noV4l2) std::thread(CameraLoop).detach();

    const int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(kPort);
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    if (bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(listener, 8) != 0) {
        std::fprintf(stderr, "Cannot listen on port %u (error %d). Is another receiver running?\n", kPort, errno);
        return 1;
    }
    std::printf("CamNexo receiver listening on TCP %u. Enter one of these in the phone app:\n", kPort);
    PrintAddresses();
    std::printf("\n");
    if (!g_noDiscovery) StartMdns();
    std::thread(WatchStdin).detach();
    if (simulate > 0) AddSimulatedSources(std::min(simulate, 8));

    for (;;) {
        sockaddr_in peer{};
        socklen_t plen = sizeof(peer);
        const int c = accept4(listener, reinterpret_cast<sockaddr*>(&peer), &plen, SOCK_CLOEXEC);
        if (c < 0) continue;
        int nodelay = 1;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
        char ip[64]{};
        inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
        std::thread(ServeClient, c, std::string(ip)).detach();
    }
}
