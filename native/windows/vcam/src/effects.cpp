// Camera effects: background blur, background replacement and colour filters.
//
// The person matte comes from MODNet (Apache-2.0, ONNX) run by ONNX Runtime, which is loaded from
// onnxruntime.dll at run time so the receiver still works without it. The matte is worked out on a
// helper thread per camera; the picture thread blends each picture with the newest matte.

#include "effects.h"

#ifdef _WIN32
#include <wincodec.h>
#include <wrl/client.h>
#else
#include <dlfcn.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "onnxruntime_c_api.h"

#ifdef _WIN32
using Microsoft::WRL::ComPtr;
#else
// Reads pictures on Linux (stb_image, public domain: third_party/stb).
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO_FAILURE_STRINGS
#include "stb_image.h"
#endif

namespace fx {
namespace {

const OrtApi* g_ort = nullptr;
OrtEnv* g_env = nullptr;
OrtSession* g_session = nullptr;
OrtMemoryInfo* g_mem = nullptr;
std::atomic<bool> g_ready{false};  // set once, possibly while the receiver is already running

// MODNet is fully convolutional (sizes in steps of 32). A small size is enough to tell the person from
// the room, and keeps one run to a few tens of milliseconds.
constexpr int kLong = 256;
constexpr int kShort = 160;

bool Ok(OrtStatus* st, std::string* why) {
    if (!st) return true;
    if (why) *why = g_ort->GetErrorMessage(st);
    g_ort->ReleaseStatus(st);
    return false;
}

inline BYTE Clamp8(int v) { return static_cast<BYTE>(v < 0 ? 0 : v > 255 ? 255 : v); }

// Runs the model on an RGB picture (w x h, 3 bytes per pixel) and writes the person alpha (0..1) to `out`.
bool Matte(const BYTE* rgb, int w, int h, float* out) {
    const size_t plane = static_cast<size_t>(w) * h;
    std::vector<float> chw(plane * 3);
    for (size_t i = 0; i < plane; ++i)
        for (int c = 0; c < 3; ++c) chw[c * plane + i] = rgb[i * 3 + c] / 127.5f - 1.0f;
    const int64_t shape[4] = {1, 3, h, w};
    OrtValue* in = nullptr;
    OrtValue* result = nullptr;
    if (!Ok(g_ort->CreateTensorWithDataAsOrtValue(g_mem, chw.data(), chw.size() * sizeof(float), shape, 4,
                                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in), nullptr)) return false;
    const char* inNames[] = {"input"};
    const char* outNames[] = {"output"};
    const bool ran = Ok(g_ort->Run(g_session, nullptr, inNames, &in, 1, outNames, 1, &result), nullptr);
    bool good = false;
    if (ran && result) {
        float* data = nullptr;
        if (Ok(g_ort->GetTensorMutableData(result, reinterpret_cast<void**>(&data)), nullptr) && data) {
            memcpy(out, data, sizeof(float) * plane);
            good = true;
        }
    }
    if (result) g_ort->ReleaseValue(result);
    g_ort->ReleaseValue(in);
    return good;
}

// Smooth step: pulls the faint grey halo of the matte towards clean 0 and 1 while keeping soft edges.
inline float Shape(float a) {
    const float t = std::clamp((a - 0.12f) / 0.76f, 0.f, 1.f);
    return t * t * (3 - 2 * t);
}

// Bilinear lookup tables that map a picture of `n` pixels onto `m` mask samples.
struct Axis {
    std::vector<int> i0, i1;
    std::vector<int> f;  // 0..256 weight of i1
    void Build(int n, int m) {
        i0.resize(n);
        i1.resize(n);
        f.resize(n);
        for (int i = 0; i < n; ++i) {
            const float pos = std::clamp((i + 0.5f) * m / n - 0.5f, 0.f, static_cast<float>(m - 1));
            const int a = static_cast<int>(pos);
            i0[i] = a;
            i1[i] = std::min(a + 1, m - 1);
            f[i] = static_cast<int>((pos - a) * 256);
        }
    }
};

}  // namespace

bool Init(const FxString& dir, std::string* why) {
    if (g_ready) return true;
    using GetBase = const OrtApiBase*(ORT_API_CALL*)();
#ifdef _WIN32
    HMODULE dll = LoadLibraryExW((dir + L"\\onnxruntime.dll").c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!dll) {
        if (why) *why = "onnxruntime.dll was not found next to the receiver";
        return false;
    }
    auto getBase = reinterpret_cast<GetBase>(GetProcAddress(dll, "OrtGetApiBase"));
#else
    void* dll = dlopen((dir + "/libonnxruntime.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!dll) {
        if (why) *why = std::string("libonnxruntime.so could not be loaded: ") + (dlerror() ? dlerror() : "");
        return false;
    }
    auto getBase = reinterpret_cast<GetBase>(dlsym(dll, "OrtGetApiBase"));
#endif
    if (!getBase) {
        if (why) *why = "the ONNX Runtime library has no OrtGetApiBase";
        return false;
    }
    g_ort = getBase()->GetApi(ORT_API_VERSION);
    if (!g_ort) {
        if (why) *why = "onnxruntime.dll is a different version";
        return false;
    }
    if (!Ok(g_ort->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "camnexo", &g_env), why)) return false;
    OrtSessionOptions* opts = nullptr;
    if (!Ok(g_ort->CreateSessionOptions(&opts), why)) return false;
    g_ort->SetIntraOpNumThreads(opts, 3);
    g_ort->SetInterOpNumThreads(opts, 1);
    g_ort->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL);
#ifdef _WIN32
    const FxString model = dir + L"\\models\\modnet.onnx";
#else
    const FxString model = dir + "/models/modnet.onnx";
#endif
    const bool created = Ok(g_ort->CreateSession(g_env, model.c_str(), opts, &g_session), why);
    g_ort->ReleaseSessionOptions(opts);
    if (!created) {
        if (why) *why = "model: " + *why;
        return false;
    }
    if (!Ok(g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &g_mem), why)) return false;
    g_ready = true;
    return true;
}

bool Available() { return g_ready; }

#ifndef _WIN32
bool LoadImageBgra(const FxString& path, int* w, int* h, std::vector<BYTE>* bgra) {
    int iw = 0, ih = 0, comp = 0;
    unsigned char* px = stbi_load(path.c_str(), &iw, &ih, &comp, 4);  // RGBA, top-down
    if (!px) return false;
    if (iw <= 0 || ih <= 0 || iw > 16384 || ih > 16384) {
        stbi_image_free(px);
        return false;
    }
    bgra->resize(static_cast<size_t>(iw) * ih * 4);
    for (size_t i = 0; i < static_cast<size_t>(iw) * ih; ++i) {
        (*bgra)[i * 4 + 0] = px[i * 4 + 2];
        (*bgra)[i * 4 + 1] = px[i * 4 + 1];
        (*bgra)[i * 4 + 2] = px[i * 4 + 0];
        (*bgra)[i * 4 + 3] = px[i * 4 + 3];
    }
    stbi_image_free(px);
    *w = iw;
    *h = ih;
    return true;
}
#else
bool LoadImageBgra(const FxString& path, int* w, int* h, std::vector<BYTE>* bgra) {
    ComPtr<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return false;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder))) return false;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, &frame))) return false;
    ComPtr<IWICFormatConverter> conv;
    if (FAILED(factory->CreateFormatConverter(&conv))) return false;
    if (FAILED(conv->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) return false;
    UINT uw = 0, uh = 0;
    conv->GetSize(&uw, &uh);
    if (uw == 0 || uh == 0 || uw > 16384 || uh > 16384) return false;
    bgra->resize(static_cast<size_t>(uw) * uh * 4);
    if (FAILED(conv->CopyPixels(nullptr, uw * 4, static_cast<UINT>(bgra->size()), bgra->data()))) return false;
    *w = static_cast<int>(uw);
    *h = static_cast<int>(uh);
    return true;
}
#endif

// ---------------------------------------------------------------------------- filters

void ApplyFilters(Picture& p, const EffectSettings& s) {
    if (!s.filtersActive() || p.w < 2 || p.h < 2) return;
    const size_t ySize = static_cast<size_t>(p.w) * p.h;
    BYTE* y = p.nv12.data();
    BYTE* uv = y + ySize;

    // Luma: brightness and contrast around mid grey, in full range, then back to video range.
    BYTE lutY[256];
    const float contrast = 1.0f + s.contrast / 100.0f;
    const float bright = s.brightness * 0.8f;
    for (int i = 0; i < 256; ++i) {
        const float full = (i - 16) * 255.0f / 219.0f;
        const float v = (full - 128.0f) * contrast + 128.0f + bright;
        lutY[i] = Clamp8(static_cast<int>(std::lround(std::clamp(v, 0.f, 255.f) * 219.0f / 255.0f + 16.0f)));
    }
    for (size_t i = 0; i < ySize; ++i) y[i] = lutY[y[i]];

    // Colour: saturation scales U and V around 128; warmth moves them (warm = redder, less blue).
    if (s.saturation || s.warmth) {
        BYTE lutU[256], lutV[256];
        const float sat = 1.0f + s.saturation / 100.0f;
        const float shift = s.warmth * 0.14f;
        for (int i = 0; i < 256; ++i) {
            lutU[i] = Clamp8(static_cast<int>(std::lround(128 + (i - 128) * sat - shift)));
            lutV[i] = Clamp8(static_cast<int>(std::lround(128 + (i - 128) * sat + shift)));
        }
        const size_t pairs = ySize / 4;
        for (size_t i = 0; i < pairs; ++i) {
            uv[i * 2] = lutU[uv[i * 2]];
            uv[i * 2 + 1] = lutV[uv[i * 2 + 1]];
        }
    }
}

// --------------------------------------------------------------------------- the matte thread

Processor::~Processor() {
    {
        std::lock_guard<std::mutex> l(_m);
        _stop = true;
    }
    _cv.notify_all();
    if (_worker.joinable()) _worker.join();
}

void Processor::StartWorker() {
    if (!_worker.joinable()) _worker = std::thread([this] { WorkerLoop(); });
}

// Hands the newest picture to the helper thread (a smaller RGB copy). Never waits.
void Processor::Submit(const Picture& up) {
    StartWorker();
    const bool wide = up.w >= up.h;
    const int w = wide ? kLong : kShort, h = wide ? kShort : kLong;
    _rgb.resize(static_cast<size_t>(w) * h * 3);
    const BYTE* y = up.nv12.data();
    const BYTE* uv = y + static_cast<size_t>(up.w) * up.h;
    for (int j = 0; j < h; ++j) {
        for (int i = 0; i < w; ++i) {
            int R = 0, G = 0, B = 0;
            for (int k = 0; k < 4; ++k) {  // 2 x 2 samples per model pixel keep thin features from aliasing
                const float sx0 = (i + ((k & 1) ? 0.75f : 0.25f)) * up.w / w, sy0 = (j + ((k & 2) ? 0.75f : 0.25f)) * up.h / h;
                const int sx = std::min<int>(up.w - 1, static_cast<int>(sx0)), sy = std::min<int>(up.h - 1, static_cast<int>(sy0));
                const int Y = y[static_cast<size_t>(sy) * up.w + sx] - 16;
                const BYTE* px = uv + static_cast<size_t>(sy / 2) * up.w + (sx & ~1);
                const int U = px[0] - 128, V = px[1] - 128;
                const int c = 298 * Y;
                R += Clamp8((c + 409 * V + 128) >> 8);
                G += Clamp8((c - 100 * U - 208 * V + 128) >> 8);
                B += Clamp8((c + 516 * U + 128) >> 8);
            }
            BYTE* o = &_rgb[(static_cast<size_t>(j) * w + i) * 3];
            o[0] = static_cast<BYTE>(R / 4);
            o[1] = static_cast<BYTE>(G / 4);
            o[2] = static_cast<BYTE>(B / 4);
        }
    }
    {
        std::lock_guard<std::mutex> l(_m);
        _inRgb = _rgb;
        _inW = w;
        _inH = h;
        _hasInput = true;
    }
    _cv.notify_one();
}

void Processor::WorkerLoop() {
    std::vector<BYTE> rgb;
    std::vector<float> alpha;
    for (;;) {
        int w = 0, h = 0;
        {
            std::unique_lock<std::mutex> l(_m);
            _cv.wait(l, [this] { return _stop || _hasInput; });
            if (_stop) return;
            rgb.swap(_inRgb);
            w = _inW;
            h = _inH;
            _hasInput = false;
        }
        alpha.resize(static_cast<size_t>(w) * h);
        const auto t0 = std::chrono::steady_clock::now();
        const auto earliestNext = t0 + std::chrono::milliseconds(50);  // at most about 20 mattes a second per camera
        if (!Matte(rgb.data(), w, h, alpha.data())) continue;
        modelMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();

        // calm the flicker between runs, then shape the edge
        if (_smooth.size() != alpha.size()) {
            _smooth.assign(alpha.size(), 0.f);
            for (size_t i = 0; i < alpha.size(); ++i) _smooth[i] = Shape(alpha[i]);
        } else {
            for (size_t i = 0; i < alpha.size(); ++i) _smooth[i] = _smooth[i] * 0.35f + Shape(alpha[i]) * 0.65f;
        }
        Mask m;
        m.w = w;
        m.h = h;
        m.a.resize(_smooth.size());
        for (size_t i = 0; i < _smooth.size(); ++i) m.a[i] = static_cast<BYTE>(std::clamp(_smooth[i], 0.f, 1.f) * 255.f + 0.5f);
        {
            std::lock_guard<std::mutex> l(_maskMutex);
            _mask = std::move(m);
        }
        std::this_thread::sleep_until(earliestNext);  // leaves the processor to the rest of the program
    }
}

bool Processor::WaitForMask(int timeoutMs) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (std::chrono::steady_clock::now() < end) {
        {
            std::lock_guard<std::mutex> l(_maskMutex);
            if (!_mask.a.empty()) return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(4));
    }
    return false;
}

// --------------------------------------------------------------------------- background

// Mixes the picture with a blurred copy or a replacement picture, through the person mask.
void Processor::Blend(Picture& up, const EffectSettings& s, const Mask& mask) {
    const int w = static_cast<int>(up.w), h = static_cast<int>(up.h);
    const size_t ySize = static_cast<size_t>(w) * h;
    BYTE* Y = up.nv12.data();
    BYTE* UV = Y + ySize;
    const int mw = mask.w, mh = mask.h;

    // Background planes (Y at full size, UV interleaved at half size).
    const BYTE* bgY = nullptr;
    const BYTE* bgUv = nullptr;
    bool replace = false;

    if (s.mode == 2) {
        if (_bgPath != s.background || _bgW != up.w || _bgH != up.h) {
            _bgPath = s.background;
            _bgW = up.w;
            _bgH = up.h;
            _bgOk = false;
            int iw = 0, ih = 0;
            std::vector<BYTE> img;
            if (!s.background.empty() && LoadImageBgra(s.background, &iw, &ih, &img)) {
                _bgY.assign(ySize, 16);
                _bgUv.assign(ySize / 2, 128);
                // cover-fit the picture into w x h (centre crop), nearest neighbour
                const double sc = std::max(static_cast<double>(w) / iw, static_cast<double>(h) / ih);
                const double u0 = (iw - w / sc) / 2.0, v0 = (ih - h / sc) / 2.0;
                for (int j = 0; j < h; ++j) {
                    const int sy = std::clamp(static_cast<int>(v0 + (j + 0.5) / sc), 0, ih - 1);
                    for (int i = 0; i < w; ++i) {
                        const int sx = std::clamp(static_cast<int>(u0 + (i + 0.5) / sc), 0, iw - 1);
                        const BYTE* p = &img[(static_cast<size_t>(sy) * iw + sx) * 4];
                        const int B = p[0], G = p[1], R = p[2];
                        _bgY[static_cast<size_t>(j) * w + i] = Clamp8(((66 * R + 129 * G + 25 * B + 128) >> 8) + 16);
                        if ((i & 1) == 0 && (j & 1) == 0) {
                            BYTE* o = &_bgUv[static_cast<size_t>(j / 2) * w + i];
                            o[0] = Clamp8(((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128);
                            o[1] = Clamp8(((112 * R - 94 * G - 18 * B + 128) >> 8) + 128);
                        }
                    }
                }
                _bgOk = true;
            }
        }
        if (_bgOk) {
            replace = true;
            bgY = _bgY.data();
            bgUv = _bgUv.data();
        }
    }

    // Blur (also the fallback when the replacement picture cannot be read): shrink, blur, and read
    // back with bilinear filtering.
    int dw = 0, dh = 0;
    std::vector<BYTE> sY, sU, sV;
    Axis bx, by;
    if (!replace) {
        const int ds = std::max(2, (w / 240) & ~1);  // even, so the colour planes shrink by ds / 2
        dw = std::max(2, w / ds);
        dh = std::max(2, h / ds);
        sY.assign(static_cast<size_t>(dw) * dh, 0);
        sU.assign(sY.size(), 128);
        sV.assign(sY.size(), 128);
        for (int j = 0; j < dh; ++j) {
            for (int i = 0; i < dw; ++i) {
                int acc = 0, n = 0;
                for (int yy = j * ds; yy < std::min(h, (j + 1) * ds); yy += 2)
                    for (int xx = i * ds; xx < std::min(w, (i + 1) * ds); xx += 2) {
                        acc += Y[static_cast<size_t>(yy) * w + xx];
                        ++n;
                    }
                sY[static_cast<size_t>(j) * dw + i] = static_cast<BYTE>(n ? acc / n : 16);
                int au = 0, av = 0, m = 0;
                for (int yy = j * ds / 2; yy < std::min(h / 2, (j + 1) * ds / 2); ++yy)
                    for (int xx = i * ds / 2; xx < std::min(w / 2, (i + 1) * ds / 2); ++xx) {
                        au += UV[static_cast<size_t>(yy) * w + xx * 2];
                        av += UV[static_cast<size_t>(yy) * w + xx * 2 + 1];
                        ++m;
                    }
                sU[static_cast<size_t>(j) * dw + i] = static_cast<BYTE>(m ? au / m : 128);
                sV[static_cast<size_t>(j) * dw + i] = static_cast<BYTE>(m ? av / m : 128);
            }
        }
        const int radius = 1 + s.blur * 3 / 100;  // 1..4 small pixels, two passes
        auto boxBlur = [&](std::vector<BYTE>& plane) {
            std::vector<BYTE> tmp(plane.size());
            for (int pass = 0; pass < 2; ++pass) {
                for (int j = 0; j < dh; ++j)  // horizontal
                    for (int i = 0; i < dw; ++i) {
                        int acc = 0, n = 0;
                        for (int k = -radius; k <= radius; ++k) {
                            const int x = i + k;
                            if (x < 0 || x >= dw) continue;
                            acc += plane[static_cast<size_t>(j) * dw + x];
                            ++n;
                        }
                        tmp[static_cast<size_t>(j) * dw + i] = static_cast<BYTE>(acc / n);
                    }
                for (int j = 0; j < dh; ++j)  // vertical
                    for (int i = 0; i < dw; ++i) {
                        int acc = 0, n = 0;
                        for (int k = -radius; k <= radius; ++k) {
                            const int yy = j + k;
                            if (yy < 0 || yy >= dh) continue;
                            acc += tmp[static_cast<size_t>(yy) * dw + i];
                            ++n;
                        }
                        plane[static_cast<size_t>(j) * dw + i] = static_cast<BYTE>(acc / n);
                    }
            }
        };
        boxBlur(sY);
        boxBlur(sU);
        boxBlur(sV);
        bx.Build(w, dw);
        by.Build(h, dh);
    }

    // Mask lookup tables (the mask is stretched over the picture).
    Axis mx, my;
    mx.Build(w, mw);
    my.Build(h, mh);
    auto maskAt = [&](int x, int yRow0, int yRow1, int fy) {
        const BYTE* r0 = &mask.a[static_cast<size_t>(yRow0) * mw];
        const BYTE* r1 = &mask.a[static_cast<size_t>(yRow1) * mw];
        const int a = (r0[mx.i0[x]] * (256 - mx.f[x]) + r0[mx.i1[x]] * mx.f[x]) >> 8;
        const int b = (r1[mx.i0[x]] * (256 - mx.f[x]) + r1[mx.i1[x]] * mx.f[x]) >> 8;
        return (a * (256 - fy) + b * fy) >> 8;  // 0..255
    };
    auto lowAt = [&](const std::vector<BYTE>& pl, int x, int y) {
        const int a = (pl[static_cast<size_t>(by.i0[y]) * dw + bx.i0[x]] * (256 - bx.f[x]) + pl[static_cast<size_t>(by.i0[y]) * dw + bx.i1[x]] * bx.f[x]) >> 8;
        const int b = (pl[static_cast<size_t>(by.i1[y]) * dw + bx.i0[x]] * (256 - bx.f[x]) + pl[static_cast<size_t>(by.i1[y]) * dw + bx.i1[x]] * bx.f[x]) >> 8;
        return (a * (256 - by.f[y]) + b * by.f[y]) >> 8;
    };

    auto blendRows = [&](int jStart, int jEnd) {
        for (int j = jStart; j < jEnd; ++j) {
            const int r0 = my.i0[j], r1 = my.i1[j], fy = my.f[j];
            BYTE* row = Y + static_cast<size_t>(j) * w;
            for (int i = 0; i < w; ++i) {
                const int m = maskAt(i, r0, r1, fy);
                if (m >= 255) continue;  // fully the person
                const int bg = replace ? bgY[static_cast<size_t>(j) * w + i] : lowAt(sY, i, j);
                row[i] = static_cast<BYTE>((row[i] * m + bg * (255 - m)) / 255);
            }
            if ((j & 1) == 0) {
                BYTE* urow = UV + static_cast<size_t>(j / 2) * w;
                for (int i = 0; i < w; i += 2) {
                    const int m = maskAt(i, r0, r1, fy);
                    if (m >= 255) continue;
                    int bu, bv;
                    if (replace) {
                        bu = bgUv[static_cast<size_t>(j / 2) * w + i];
                        bv = bgUv[static_cast<size_t>(j / 2) * w + i + 1];
                    } else {
                        bu = lowAt(sU, i, j);
                        bv = lowAt(sV, i, j);
                    }
                    urow[i] = static_cast<BYTE>((urow[i] * m + bu * (255 - m)) / 255);
                    urow[i + 1] = static_cast<BYTE>((urow[i + 1] * m + bv * (255 - m)) / 255);
                }
            }
        }
    };

    // Bands of rows are independent, so split them over a few threads (band edges stay even so the
    // colour rows pair up).
    const int threads = std::clamp(static_cast<int>(std::thread::hardware_concurrency()) / 3, 1, 4);
    if (threads <= 1 || h < 256) {
        blendRows(0, h);
    } else {
        std::vector<std::thread> pool;
        const int band = ((h / threads) + 1) & ~1;
        for (int k = 0; k < threads; ++k) {
            const int a = k * band, b = (k == threads - 1) ? h : std::min(h, (k + 1) * band);
            if (a >= b) break;
            pool.emplace_back(blendRows, a, b);
        }
        for (auto& th : pool) th.join();
    }
}

std::shared_ptr<const Picture> Processor::Process(const std::shared_ptr<const Picture>& in, int rotation,
                                                  const EffectSettings& s) {
    if (!in || in->w < 2 || in->h < 2 || !s.active()) return in;
    const auto t0 = std::chrono::steady_clock::now();
    auto out = std::make_shared<Picture>();

    const bool background = s.mode != 0 && Available();
    if (!background) {
        // Colour filters only: work on a copy at the original size and orientation.
        *out = *in;
        ApplyFilters(*out, s);
    } else {
        // Turn the picture upright (the person is the right way up for the model) and keep it to about
        // Full HD, which keeps the work per picture small.
        const int rot = in->upright ? 0 : (((rotation % 360) + 360) % 360) / 90 * 90;
        const bool quarter = rot == 90 || rot == 270;
        const double rw = quarter ? in->h : in->w, rh = quarter ? in->w : in->h;
        const double scale = std::min(1.0, std::sqrt(1920.0 * 1080.0 / (rw * rh)));
        const int ow = std::max(2, static_cast<int>(rw * scale) & ~1);
        const int oh = std::max(2, static_cast<int>(rh * scale) & ~1);
        out->w = static_cast<uint32_t>(ow);
        out->h = static_cast<uint32_t>(oh);
        out->ts100ns = in->ts100ns;
        out->upright = true;
        out->nv12.assign(static_cast<size_t>(ow) * oh * 3 / 2, 0);
        memset(out->nv12.data(), 16, static_cast<size_t>(ow) * oh);
        memset(out->nv12.data() + static_cast<size_t>(ow) * oh, 128, static_cast<size_t>(ow) * oh / 2);
        DrawCell(*in, rot, false, out->nv12.data(), out->nv12.data() + static_cast<size_t>(ow) * oh, ow, 0, 0, ow, oh);

        Submit(*out);
        bool have;
        {
            std::lock_guard<std::mutex> l(_maskMutex);
            have = !_mask.a.empty();
        }
        if (!have) WaitForMask(600);  // the very first picture waits for its first matte
        Mask m;
        {
            std::lock_guard<std::mutex> l(_maskMutex);
            m = _mask;
        }
        if (!m.a.empty()) Blend(*out, s, m);
        ApplyFilters(*out, s);
    }
    lastMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    return out;
}

}  // namespace fx
