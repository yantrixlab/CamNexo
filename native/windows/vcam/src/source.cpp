// CamNexo virtual camera spike: a Media Foundation media source that emits an NV12 test pattern.
// Loaded by the Windows Frame Server (FrameServer service) through MFCreateVirtualCamera.

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <strmif.h>
#include <ks.h>
#include <ksproxy.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <vector>
#include <atomic>
#include <chrono>
#include <deque>
#include <mutex>
#include <thread>

#include "frame_pipe.h"
#include "ids.h"

using Microsoft::WRL::ChainInterfaces;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;

namespace {

constexpr UINT32 kFps = 30;

// The sizes the camera offers to apps (all 16:9, NV12, 30 fps). An app picks one; the picture from
// the phone is scaled to it. The default is what apps that do not choose get.
struct FrameSize {
    UINT32 w, h;
};
constexpr FrameSize kSizes[] = {{640, 360}, {1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}};
constexpr size_t kSizeCount = sizeof(kSizes) / sizeof(kSizes[0]);
constexpr size_t kDefaultSize = 1;  // 1280x720

constexpr size_t NV12Bytes(UINT32 w, UINT32 h) { return static_cast<size_t>(w) * h * 3 / 2; }

// PINNAME_VIDEO_CAPTURE
constexpr GUID kPinVideoCapture =
    {0xfb6c4281, 0x0353, 0x11d1, {0x90, 0x5f, 0x00, 0x00, 0xc0, 0xcc, 0x16, 0xba}};
// KSCAMERAPROFILE_Legacy / KSCAMERAPROFILE_HighFrameRate
constexpr GUID kProfileLegacy =
    {0xb4894d81, 0x62b7, 0x4eec, {0x87, 0x40, 0x80, 0x65, 0x8c, 0x4a, 0x9d, 0x3e}};
constexpr GUID kProfileHighFrameRate =
    {0x566e6113, 0x8c35, 0x48e7, {0xb8, 0x9f, 0xd2, 0x3f, 0xdc, 0x12, 0x19, 0xdc}};

// Debug output plus a best-effort log file. The Frame Server runs as LocalService; it can write here
// only because %ProgramData%\CamNexo\vcam grants Users write access.
void Log(const wchar_t* fmt, ...) {
    wchar_t msg[512];
    va_list args;
    va_start(args, fmt);
    _vsnwprintf_s(msg, _TRUNCATE, fmt, args);
    va_end(args);
    OutputDebugStringW(msg);

    wchar_t path[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"ProgramData", path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH - 32) return;
    // One file per process: the service identity cannot append to files created by another user.
    wchar_t name[48];
    _snwprintf_s(name, _TRUNCATE, L"\\CamNexo\\vcam\\vcam-%lu.log", GetCurrentProcessId());
    wcscat_s(path, name);
    HANDLE f = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t line[640];
    int len = _snwprintf_s(line, _TRUNCATE, L"%02d:%02d:%02d.%03d [%lu] %s", t.wHour, t.wMinute, t.wSecond,
                           t.wMilliseconds, GetCurrentProcessId(), msg);
    // Write as UTF-8-ish ASCII: messages are ASCII.
    char out[640];
    int m = WideCharToMultiByte(CP_UTF8, 0, line, len, out, sizeof(out), nullptr, nullptr);
    DWORD written;
    WriteFile(f, out, m, &written, nullptr);
    CloseHandle(f);
}

// Eight colour bars that rotate every half second, plus a moving white box so motion is obvious.
// Shown when no phone is streaming.
void FillNv12(BYTE* dst, UINT64 frame, UINT32 width, UINT32 height) {
    static const BYTE Y[8] = {235, 210, 170, 145, 106, 81, 41, 16};
    static const BYTE U[8] = {128, 16, 166, 54, 202, 90, 240, 128};
    static const BYTE V[8] = {128, 146, 16, 34, 222, 240, 110, 128};
    const UINT shift = static_cast<UINT>((frame / 15) % 8);

    BYTE* yPlane = dst;
    for (UINT32 y = 0; y < height; ++y) {
        for (UINT32 x = 0; x < width; ++x) {
            yPlane[static_cast<size_t>(y) * width + x] = Y[(x * 8 / width + shift) % 8];
        }
    }
    BYTE* uvPlane = dst + static_cast<size_t>(width) * height;
    for (UINT32 y = 0; y < height / 2; ++y) {
        for (UINT32 x = 0; x < width / 2; ++x) {
            const UINT bar = (x * 2 * 8 / width + shift) % 8;
            uvPlane[static_cast<size_t>(y) * width + x * 2] = U[bar];
            uvPlane[static_cast<size_t>(y) * width + x * 2 + 1] = V[bar];
        }
    }

    const UINT32 box = height / 8;
    const UINT32 bx = static_cast<UINT32>((frame * 8) % (width - box)) & ~1u;
    const UINT32 by = (height / 2 - box / 2) & ~1u;
    for (UINT32 y = by; y < by + box; ++y) {
        for (UINT32 x = bx; x < bx + box; ++x) yPlane[static_cast<size_t>(y) * width + x] = 235;
    }
    for (UINT32 y = by / 2; y < (by + box) / 2; ++y) {
        for (UINT32 x = bx; x < bx + box; x += 2) {
            uvPlane[static_cast<size_t>(y) * width + x] = 128;
            uvPlane[static_cast<size_t>(y) * width + x + 1] = 128;
        }
    }
}

// Scales an NV12 picture to another size (nearest neighbour), keeping the aspect ratio and filling
// the rest with black. The pictures from the phone are 16:9 like every size offered, so normally
// it fills the frame exactly. `xmap` is scratch space reused between calls.
void ScaleNv12(const BYTE* src, UINT32 sw, UINT32 sh, BYTE* dst, UINT32 dw, UINT32 dh, std::vector<UINT32>& xmap) {
    if (sw == dw && sh == dh) {
        memcpy(dst, src, NV12Bytes(dw, dh));
        return;
    }
    const double s = std::min(static_cast<double>(dw) / sw, static_cast<double>(dh) / sh);
    const UINT32 fw = static_cast<UINT32>(sw * s) & ~1u, fh = static_cast<UINT32>(sh * s) & ~1u;
    const UINT32 ox = ((dw - fw) / 2) & ~1u, oy = ((dh - fh) / 2) & ~1u;
    if (fw < 2 || fh < 2) return;
    if (fw != dw || fh != dh) {  // bars around the picture
        memset(dst, 16, static_cast<size_t>(dw) * dh);
        memset(dst + static_cast<size_t>(dw) * dh, 128, static_cast<size_t>(dw) * dh / 2);
    }
    xmap.resize(fw);
    for (UINT32 x = 0; x < fw; ++x) xmap[x] = std::min<UINT32>(sw - 1, static_cast<UINT32>(x / s));

    const BYTE* srcUv = src + static_cast<size_t>(sw) * sh;
    BYTE* dstUv = dst + static_cast<size_t>(dw) * dh;
    for (UINT32 y = 0; y < fh; ++y) {
        const UINT32 sy = std::min<UINT32>(sh - 1, static_cast<UINT32>(y / s));
        const BYTE* row = src + static_cast<size_t>(sy) * sw;
        BYTE* out = dst + static_cast<size_t>(oy + y) * dw + ox;
        for (UINT32 x = 0; x < fw; ++x) out[x] = row[xmap[x]];
    }
    for (UINT32 y = 0; y < fh / 2; ++y) {
        const UINT32 sy = std::min<UINT32>(sh - 1, static_cast<UINT32>((y * 2) / s)) / 2;
        const BYTE* row = srcUv + static_cast<size_t>(sy) * sw;
        BYTE* out = dstUv + static_cast<size_t>(oy / 2 + y) * dw + ox;
        for (UINT32 x = 0; x < fw / 2; ++x) {
            const BYTE* px = row + (xmap[x * 2] & ~1u);
            out[x * 2] = px[0];
            out[x * 2 + 1] = px[1];
        }
    }
}

// Reads decoded NV12 frames from the receiver's named pipe and keeps the newest one.
// CopyLatest() fails when no phone is streaming, and the caller falls back to the test pattern.
class FramePipeReader {
public:
    void Start() {
        if (_running.exchange(true)) return;
        _thread = std::thread([this] { Loop(); });
    }

    void Stop() {
        if (!_running.exchange(false)) return;
        if (_thread.joinable()) {
            CancelSynchronousIo(_thread.native_handle());  // wake a blocked ReadFile
            _thread.join();
        }
    }

    // Copies the newest picture into `dst` (a dw x dh NV12 buffer), scaled if the sizes differ.
    bool CopyLatest(BYTE* dst, UINT32 dw, UINT32 dh) {
        std::lock_guard<std::mutex> l(_m);
        if (_fw == 0 || _frame.size() != NV12Bytes(_fw, _fh)) return false;
        if (GetTickCount64() - _tick > 1000) return false;  // stale: the phone went away
        ScaleNv12(_frame.data(), _fw, _fh, dst, dw, dh, _xmap);
        return true;
    }

private:
    static bool ReadAll(HANDLE h, void* buf, size_t n) {
        BYTE* p = static_cast<BYTE*>(buf);
        while (n) {
            DWORD got = 0;
            if (!ReadFile(h, p, static_cast<DWORD>(n), &got, nullptr) || got == 0) return false;
            p += got;
            n -= got;
        }
        return true;
    }

    void Loop();

    std::atomic<bool> _running{false};
    std::thread _thread;
    std::mutex _m;
    std::vector<BYTE> _frame;
    std::vector<UINT32> _xmap;
    UINT32 _fw = 0, _fh = 0;  // size of _frame
    ULONGLONG _tick = 0;
};

void LogGuid(const wchar_t* what, REFGUID g, HRESULT hr) {
    wchar_t s[64] = L"?";
    StringFromGUID2(g, s, 64);
    Log(L"%s %s -> 0x%08lx\n", what, s, hr);
}

void FramePipeReader::Loop() {
    std::vector<BYTE> tmp;
    while (_running) {
        HANDLE h = CreateFileW(CAMNEXO_FRAME_PIPE, GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) {
            Sleep(500);
            continue;
        }
        Log(L"frame pipe connected\n");
        while (_running) {
            FramePipeHeader hd;
            if (!ReadAll(h, &hd, sizeof(hd)) || hd.magic != kFramePipeMagic) break;
            // The picture can be any even size up to 4K; reject anything else rather than trust it.
            if (hd.width < 2 || hd.height < 2 || hd.width > kMaxFrameWidth || hd.height > kMaxFrameHeight ||
                (hd.width & 1) || (hd.height & 1))
                break;
            tmp.resize(NV12Bytes(hd.width, hd.height));
            if (!ReadAll(h, tmp.data(), tmp.size())) break;
            std::lock_guard<std::mutex> l(_m);
            _frame.swap(tmp);  // tmp is resized again on the next frame
            _fw = hd.width;
            _fh = hd.height;
            _tick = GetTickCount64();
        }
        CloseHandle(h);
        Log(L"frame pipe lost\n");
    }
}

class CamNexoSource;

class CamNexoStream
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                          ChainInterfaces<IMFMediaStream2, IMFMediaStream, IMFMediaEventGenerator>,
                          IKsControl, IMFSampleAllocatorControl> {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        HRESULT hr = RuntimeClass::QueryInterface(riid, ppv);
        if (FAILED(hr)) LogGuid(L"stream QI", riid, hr);
        return hr;
    }

    HRESULT Init(IMFMediaSource* source, IMFStreamDescriptor* sd) {
        _source = source;
        _descriptor = sd;
        return MFCreateEventQueue(&_queue);
    }

    // IMFMediaEventGenerator
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** ev) override {
        ComPtr<IMFMediaEventQueue> q;
        { std::lock_guard<std::mutex> l(_lock); if (!_queue) return MF_E_SHUTDOWN; q = _queue; }
        return q->GetEvent(flags, ev);
    }
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* cb, IUnknown* state) override {
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        return _queue->BeginGetEvent(cb, state);
    }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* r, IMFMediaEvent** ev) override {
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        return _queue->EndGetEvent(r, ev);
    }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID ext, HRESULT hr, const PROPVARIANT* v) override {
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        return _queue->QueueEventParamVar(t, ext, hr, v);
    }

    // IMFMediaStream
    STDMETHODIMP GetMediaSource(IMFMediaSource** s) override {
        if (!s) return E_POINTER;
        _source.CopyTo(s);
        return S_OK;
    }
    STDMETHODIMP GetStreamDescriptor(IMFStreamDescriptor** sd) override {
        Log(L"stream GetStreamDescriptor\n");
        if (!sd) return E_POINTER;
        _descriptor.CopyTo(sd);
        return S_OK;
    }
    STDMETHODIMP RequestSample(IUnknown* token) override {
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        _tokens.emplace_back(token);
        if (_tokens.size() <= 2) Log(L"stream RequestSample (pending=%zu)\n", _tokens.size());
        return S_OK;
    }

    // IMFMediaStream2
    STDMETHODIMP SetStreamState(MF_STREAM_STATE state) override {
        Log(L"stream SetStreamState %d\n", static_cast<int>(state));
        _state = state;
        return S_OK;
    }
    STDMETHODIMP GetStreamState(MF_STREAM_STATE* state) override {
        Log(L"stream GetStreamState\n");
        if (!state) return E_POINTER;
        *state = _state;
        return S_OK;
    }

    // IKsControl: no KS properties are supported by this source.
    STDMETHODIMP KsProperty(PKSPROPERTY, ULONG, LPVOID, ULONG, ULONG*) override {
        Log(L"stream KsProperty\n");
        return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
    }
    STDMETHODIMP KsMethod(PKSMETHOD, ULONG, LPVOID, ULONG, ULONG*) override {
        Log(L"stream KsMethod\n");
        return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
    }
    STDMETHODIMP KsEvent(PKSEVENT, ULONG, LPVOID, ULONG, ULONG*) override {
        Log(L"stream KsEvent\n");
        return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
    }

    // IMFSampleAllocatorControl
    STDMETHODIMP SetDefaultAllocator(DWORD, IUnknown*) override { Log(L"stream SetDefaultAllocator\n"); return S_OK; }
    STDMETHODIMP GetAllocatorUsage(DWORD streamId, DWORD* inputId, MFSampleAllocatorUsage* usage) override {
        Log(L"stream GetAllocatorUsage\n");
        if (!inputId || !usage) return E_POINTER;
        *inputId = streamId;
        *usage = MFSampleAllocatorUsage_DoesNotAllocate;
        return S_OK;
    }

    /// The size the app selected for the stream; used for every frame until it changes it again.
    void SetOutputSize(UINT32 w, UINT32 h) {
        for (const FrameSize& s : kSizes) {
            if (s.w == w && s.h == h) {
                if (_outW != w || _outH != h) Log(L"stream output size %ux%u\n", w, h);
                _outW = w;
                _outH = h;
                return;
            }
        }
        Log(L"stream: ignoring unknown output size %ux%u\n", w, h);
    }

    HRESULT Start() {
        {
            std::lock_guard<std::mutex> l(_lock);
            if (!_queue) return MF_E_SHUTDOWN;
            if (_running) return S_OK;
            _running = true;
            _state = MF_STREAM_STATE_RUNNING;
            _frame = 0;
            _startTime = MFGetSystemTime();
            _queue->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, nullptr);
        }
        _pipe.Start();
        _thread = std::thread([this] { Run(); });
        return S_OK;
    }

    HRESULT Stop() {
        {
            std::lock_guard<std::mutex> l(_lock);
            if (!_running) return S_OK;
            _running = false;
            _state = MF_STREAM_STATE_STOPPED;
        }
        Log(L"stream Stop\n");
        if (_thread.joinable()) _thread.join();
        _pipe.Stop();
        std::lock_guard<std::mutex> l(_lock);
        _tokens.clear();
        if (_queue) _queue->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, nullptr);
        return S_OK;
    }

    void Shutdown() {
        Stop();
        std::lock_guard<std::mutex> l(_lock);
        if (_queue) { _queue->Shutdown(); _queue.Reset(); }
        _source.Reset();
    }

private:
    void Run() {
        auto next = std::chrono::steady_clock::now();
        for (;;) {
            next += std::chrono::microseconds(1000000 / kFps);
            std::this_thread::sleep_until(next);

            ComPtr<IUnknown> token;
            ComPtr<IMFMediaEventQueue> q;
            UINT64 frame;
            LONGLONG ts;
            {
                std::lock_guard<std::mutex> l(_lock);
                if (!_running) return;
                if (_tokens.empty() || !_queue) continue;
                token = std::move(_tokens.front());
                _tokens.pop_front();
                q = _queue;
                frame = _frame++;
                // Absolute system time, like a real capture device; the Frame Server drops samples that look stale.
                ts = MFGetSystemTime();
            }

            // The size the app chose for this stream (see SetOutputSize).
            const UINT32 fw = _outW, fh = _outH;
            const DWORD frameBytes = static_cast<DWORD>(NV12Bytes(fw, fh));
            ComPtr<IMFMediaBuffer> buffer;
            if (FAILED(MFCreateMemoryBuffer(frameBytes, &buffer))) continue;
            BYTE* data = nullptr;
            if (FAILED(buffer->Lock(&data, nullptr, nullptr))) continue;
            const bool live = _pipe.CopyLatest(data, fw, fh);
            if (!live) FillNv12(data, frame, fw, fh);
            if (live != _wasLive) {
                _wasLive = live;
                Log(live ? L"stream: showing phone frames\n" : L"stream: showing test pattern\n");
            }
            buffer->Unlock();
            buffer->SetCurrentLength(frameBytes);

            ComPtr<IMFSample> sample;
            if (FAILED(MFCreateSample(&sample))) continue;
            sample->AddBuffer(buffer.Get());
            sample->SetSampleTime(ts);
            sample->SetSampleDuration(10000000LL / kFps);
            sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);
            if (token) sample->SetUnknown(MFSampleExtension_Token, token.Get());
            HRESULT qhr = q->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample.Get());
            if (frame < 3 || frame % 90 == 0 || FAILED(qhr)) Log(L"stream sample %llu queued 0x%08lx\n", frame, qhr);
        }
    }

    std::mutex _lock;
    ComPtr<IMFMediaEventQueue> _queue;
    ComPtr<IMFMediaSource> _source;
    ComPtr<IMFStreamDescriptor> _descriptor;
    std::deque<ComPtr<IUnknown>> _tokens;
    FramePipeReader _pipe;
    std::atomic<UINT32> _outW{kSizes[kDefaultSize].w};
    std::atomic<UINT32> _outH{kSizes[kDefaultSize].h};
    bool _wasLive = false;
    std::thread _thread;
    bool _running = false;
    UINT64 _frame = 0;
    LONGLONG _startTime = 0;
    std::atomic<MF_STREAM_STATE> _state{MF_STREAM_STATE_STOPPED};
};

class CamNexoSource
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                          ChainInterfaces<IMFMediaSource2, IMFMediaSourceEx, IMFMediaSource, IMFMediaEventGenerator>,
                          IMFGetService, IKsControl, IMFSampleAllocatorControl> {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        HRESULT hr = RuntimeClass::QueryInterface(riid, ppv);
        if (FAILED(hr)) LogGuid(L"source QI", riid, hr);
        return hr;
    }

    HRESULT RuntimeClassInitialize() {
        HRESULT hr = MFCreateEventQueue(&_queue);
        if (FAILED(hr)) return hr;
        hr = MFCreateAttributes(&_attributes, 1);
        if (FAILED(hr)) return hr;

        // Camera profiles: Legacy is mandatory, HighFrameRate keeps profile-aware apps happy.
        ComPtr<IMFSensorProfileCollection> profiles;
        hr = MFCreateSensorProfileCollection(&profiles);
        if (FAILED(hr)) return hr;
        ComPtr<IMFSensorProfile> profile;
        hr = MFCreateSensorProfile(kProfileLegacy, 0, nullptr, &profile);
        if (FAILED(hr)) return hr;
        profile->AddProfileFilter(0, L"((RES==;FRT<=30,1;SUT==))");
        profiles->AddProfile(profile.Get());
        profile.Reset();
        hr = MFCreateSensorProfile(kProfileHighFrameRate, 0, nullptr, &profile);
        if (FAILED(hr)) return hr;
        profile->AddProfileFilter(0, L"((RES==;FRT>=60,1;SUT==))");
        profiles->AddProfile(profile.Get());
        _attributes->SetUnknown(MF_DEVICEMFT_SENSORPROFILE_COLLECTION, profiles.Get());

        // One media type per offered size; the app picks one.
        ComPtr<IMFMediaType> types[kSizeCount];
        IMFMediaType* raw[kSizeCount];
        for (size_t i = 0; i < kSizeCount; ++i) {
            const UINT32 w = kSizes[i].w, h = kSizes[i].h;
            hr = MFCreateMediaType(&types[i]);
            if (FAILED(hr)) return hr;
            IMFMediaType* t = types[i].Get();
            t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
            t->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
            MFSetAttributeSize(t, MF_MT_FRAME_SIZE, w, h);
            MFSetAttributeRatio(t, MF_MT_FRAME_RATE, kFps, 1);
            MFSetAttributeRatio(t, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
            t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
            t->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
            t->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
            t->SetUINT32(MF_MT_DEFAULT_STRIDE, w);
            t->SetUINT32(MF_MT_SAMPLE_SIZE, static_cast<UINT32>(NV12Bytes(w, h)));
            raw[i] = t;
        }
        ComPtr<IMFMediaType> type = types[kDefaultSize];

        hr = MFCreateStreamDescriptor(0, static_cast<DWORD>(kSizeCount), raw, &_descriptor);
        if (FAILED(hr)) return hr;
        _descriptor->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY, kPinVideoCapture);
        _descriptor->SetUINT32(MF_DEVICESTREAM_STREAM_ID, 0);
        _descriptor->SetUINT32(MF_DEVICESTREAM_FRAMESERVER_SHARED, 1);
        _descriptor->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, MFFrameSourceTypes_Color);

        ComPtr<IMFMediaTypeHandler> handler;
        hr = _descriptor->GetMediaTypeHandler(&handler);
        if (FAILED(hr)) return hr;
        hr = handler->SetCurrentMediaType(type.Get());
        if (FAILED(hr)) return hr;

        _stream = Make<CamNexoStream>();
        if (!_stream) return E_OUTOFMEMORY;
        return _stream->Init(this, _descriptor.Get());
    }

    // IMFMediaEventGenerator
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** ev) override {
        ComPtr<IMFMediaEventQueue> q;
        { std::lock_guard<std::mutex> l(_lock); if (!_queue) return MF_E_SHUTDOWN; q = _queue; }
        return q->GetEvent(flags, ev);
    }
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* cb, IUnknown* state) override {
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        return _queue->BeginGetEvent(cb, state);
    }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* r, IMFMediaEvent** ev) override {
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        return _queue->EndGetEvent(r, ev);
    }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID ext, HRESULT hr, const PROPVARIANT* v) override {
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        return _queue->QueueEventParamVar(t, ext, hr, v);
    }

    // IMFMediaSource
    STDMETHODIMP GetCharacteristics(DWORD* c) override {
        Log(L"source GetCharacteristics\n");
        if (!c) return E_POINTER;
        *c = MFMEDIASOURCE_IS_LIVE;
        return S_OK;
    }
    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** ppd) override {
        Log(L"source CreatePresentationDescriptor\n");
        if (!ppd) return E_POINTER;
        IMFStreamDescriptor* sds[] = {_descriptor.Get()};
        ComPtr<IMFPresentationDescriptor> pd;
        HRESULT hr = MFCreatePresentationDescriptor(1, sds, &pd);
        if (FAILED(hr)) return hr;
        pd->SelectStream(0);
        *ppd = pd.Detach();
        return S_OK;
    }
    STDMETHODIMP Start(IMFPresentationDescriptor* pd, const GUID* timeFormat, const PROPVARIANT* startPos) override {
        Log(L"source Start pd=%p timeFormat=%p startPos=%p\n", pd, timeFormat, startPos);
        if (timeFormat && *timeFormat != GUID_NULL) return MF_E_UNSUPPORTED_TIME_FORMAT;
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;

        // The app's chosen format is the current type on the descriptor it passes in.
        if (pd) {
            BOOL selected = FALSE;
            ComPtr<IMFStreamDescriptor> sd;
            ComPtr<IMFMediaTypeHandler> handler;
            ComPtr<IMFMediaType> current;
            UINT32 w = 0, h = 0;
            if (SUCCEEDED(pd->GetStreamDescriptorByIndex(0, &selected, &sd)) &&
                SUCCEEDED(sd->GetMediaTypeHandler(&handler)) && SUCCEEDED(handler->GetCurrentMediaType(&current)) &&
                SUCCEEDED(MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h))) {
                _stream->SetOutputSize(w, h);
            }
        }

        // Order per the Frame Server custom media source doc: MESourceStarted, then MENewStream, then the
        // stream's own MEStreamStarted.
        PROPVARIANT pos;
        PropVariantInit(&pos);
        pos.vt = VT_I8;
        pos.hVal.QuadPart = MFGetSystemTime();
        HRESULT hr = _queue->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, &pos);
        if (FAILED(hr)) return hr;
        hr = _queue->QueueEventParamUnk(MENewStream, GUID_NULL, S_OK, static_cast<IMFMediaStream*>(_stream.Get()));
        if (FAILED(hr)) return hr;
        return _stream->Start();
    }
    STDMETHODIMP Stop() override {
        Log(L"CamNexo vcam: source Stop\n");
        _stream->Stop();
        std::lock_guard<std::mutex> l(_lock);
        if (!_queue) return MF_E_SHUTDOWN;
        return _queue->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, nullptr);
    }
    STDMETHODIMP Pause() override { return MF_E_INVALID_STATE_TRANSITION; }
    STDMETHODIMP Shutdown() override {
        Log(L"CamNexo vcam: source Shutdown\n");
        if (_stream) _stream->Shutdown();
        std::lock_guard<std::mutex> l(_lock);
        if (_queue) { _queue->Shutdown(); _queue.Reset(); }
        return S_OK;
    }

    // IMFMediaSourceEx
    STDMETHODIMP GetSourceAttributes(IMFAttributes** a) override {
        Log(L"source GetSourceAttributes\n");
        if (!a) return E_POINTER;
        _attributes.CopyTo(a);
        return S_OK;
    }
    STDMETHODIMP GetStreamAttributes(DWORD id, IMFAttributes** a) override {
        Log(L"source GetStreamAttributes(%lu)\n", id);
        if (!a) return E_POINTER;
        if (id != 0) return MF_E_INVALIDSTREAMNUMBER;
        return _descriptor.CopyTo(a);
    }
    STDMETHODIMP SetD3DManager(IUnknown*) override { Log(L"source SetD3DManager\n"); return S_OK; }

    // IMFMediaSource2
    STDMETHODIMP SetMediaType(DWORD streamId, IMFMediaType* type) override {
        UINT32 w = 0, h = 0;
        if (type && SUCCEEDED(MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &w, &h)) && _stream) {
            Log(L"source SetMediaType(%lu) %ux%u\n", streamId, w, h);
            _stream->SetOutputSize(w, h);
        } else {
            Log(L"source SetMediaType(%lu)\n", streamId);
        }
        return S_OK;
    }

    // IMFGetService
    STDMETHODIMP GetService(REFGUID svc, REFIID riid, LPVOID* ppv) override {
        LogGuid(L"source GetService svc", svc, 0);
        LogGuid(L"source GetService riid", riid, 0);
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        return MF_E_UNSUPPORTED_SERVICE;
    }

    // IKsControl
    STDMETHODIMP KsProperty(PKSPROPERTY p, ULONG, LPVOID, ULONG, ULONG*) override {
        if (p) LogGuid(L"source KsProperty set", p->Set, static_cast<HRESULT>(p->Id));
        return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
    }
    STDMETHODIMP KsMethod(PKSMETHOD p, ULONG, LPVOID, ULONG, ULONG*) override {
        if (p) LogGuid(L"source KsMethod set", p->Set, static_cast<HRESULT>(p->Id));
        return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
    }
    STDMETHODIMP KsEvent(PKSEVENT p, ULONG, LPVOID, ULONG, ULONG*) override {
        if (p) LogGuid(L"source KsEvent set", p->Set, static_cast<HRESULT>(p->Id));
        return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
    }

    // IMFSampleAllocatorControl
    STDMETHODIMP SetDefaultAllocator(DWORD, IUnknown*) override { Log(L"source SetDefaultAllocator\n"); return S_OK; }
    STDMETHODIMP GetAllocatorUsage(DWORD streamId, DWORD* inputId, MFSampleAllocatorUsage* usage) override {
        Log(L"source GetAllocatorUsage\n");
        if (!inputId || !usage) return E_POINTER;
        *inputId = streamId;
        *usage = MFSampleAllocatorUsage_DoesNotAllocate;
        return S_OK;
    }

private:
    std::mutex _lock;
    ComPtr<IMFMediaEventQueue> _queue;
    ComPtr<IMFAttributes> _attributes;
    ComPtr<IMFStreamDescriptor> _descriptor;
    ComPtr<CamNexoStream> _stream;
};

// The Frame Server instantiates the registered CLSID as an IMFActivate and asks it for the media source.
class CamNexoActivate
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, ChainInterfaces<IMFActivate, IMFAttributes>> {
public:
    HRESULT RuntimeClassInitialize() { return MFCreateAttributes(&_attrs, 0); }

    // IMFActivate
    STDMETHODIMP ActivateObject(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        Log(L"CamNexo vcam: ActivateObject\n");
        ComPtr<CamNexoSource> src;
        HRESULT hr = Microsoft::WRL::MakeAndInitialize<CamNexoSource>(&src);
        if (FAILED(hr)) return hr;
        return src.CopyTo(riid, ppv);
    }
    STDMETHODIMP ShutdownObject() override { return S_OK; }
    STDMETHODIMP DetachObject() override { return E_NOTIMPL; }

    // IMFAttributes: forwarded to the internal store.
    STDMETHODIMP GetItem(REFGUID k, PROPVARIANT* v) override { return _attrs->GetItem(k, v); }
    STDMETHODIMP GetItemType(REFGUID k, MF_ATTRIBUTE_TYPE* t) override { return _attrs->GetItemType(k, t); }
    STDMETHODIMP CompareItem(REFGUID k, REFPROPVARIANT v, BOOL* r) override { return _attrs->CompareItem(k, v, r); }
    STDMETHODIMP Compare(IMFAttributes* o, MF_ATTRIBUTES_MATCH_TYPE t, BOOL* r) override { return _attrs->Compare(o, t, r); }
    STDMETHODIMP GetUINT32(REFGUID k, UINT32* v) override { return _attrs->GetUINT32(k, v); }
    STDMETHODIMP GetUINT64(REFGUID k, UINT64* v) override { return _attrs->GetUINT64(k, v); }
    STDMETHODIMP GetDouble(REFGUID k, double* v) override { return _attrs->GetDouble(k, v); }
    STDMETHODIMP GetGUID(REFGUID k, GUID* v) override { return _attrs->GetGUID(k, v); }
    STDMETHODIMP GetStringLength(REFGUID k, UINT32* n) override { return _attrs->GetStringLength(k, n); }
    STDMETHODIMP GetString(REFGUID k, LPWSTR b, UINT32 n, UINT32* l) override { return _attrs->GetString(k, b, n, l); }
    STDMETHODIMP GetAllocatedString(REFGUID k, LPWSTR* b, UINT32* l) override { return _attrs->GetAllocatedString(k, b, l); }
    STDMETHODIMP GetBlobSize(REFGUID k, UINT32* n) override { return _attrs->GetBlobSize(k, n); }
    STDMETHODIMP GetBlob(REFGUID k, UINT8* b, UINT32 n, UINT32* l) override { return _attrs->GetBlob(k, b, n, l); }
    STDMETHODIMP GetAllocatedBlob(REFGUID k, UINT8** b, UINT32* n) override { return _attrs->GetAllocatedBlob(k, b, n); }
    STDMETHODIMP GetUnknown(REFGUID k, REFIID i, LPVOID* p) override { return _attrs->GetUnknown(k, i, p); }
    STDMETHODIMP SetItem(REFGUID k, REFPROPVARIANT v) override { return _attrs->SetItem(k, v); }
    STDMETHODIMP DeleteItem(REFGUID k) override { return _attrs->DeleteItem(k); }
    STDMETHODIMP DeleteAllItems() override { return _attrs->DeleteAllItems(); }
    STDMETHODIMP SetUINT32(REFGUID k, UINT32 v) override { return _attrs->SetUINT32(k, v); }
    STDMETHODIMP SetUINT64(REFGUID k, UINT64 v) override { return _attrs->SetUINT64(k, v); }
    STDMETHODIMP SetDouble(REFGUID k, double v) override { return _attrs->SetDouble(k, v); }
    STDMETHODIMP SetGUID(REFGUID k, REFGUID v) override { return _attrs->SetGUID(k, v); }
    STDMETHODIMP SetString(REFGUID k, LPCWSTR v) override { return _attrs->SetString(k, v); }
    STDMETHODIMP SetBlob(REFGUID k, const UINT8* b, UINT32 n) override { return _attrs->SetBlob(k, b, n); }
    STDMETHODIMP SetUnknown(REFGUID k, IUnknown* u) override { return _attrs->SetUnknown(k, u); }
    STDMETHODIMP LockStore() override { return _attrs->LockStore(); }
    STDMETHODIMP UnlockStore() override { return _attrs->UnlockStore(); }
    STDMETHODIMP GetCount(UINT32* n) override { return _attrs->GetCount(n); }
    STDMETHODIMP GetItemByIndex(UINT32 i, GUID* k, PROPVARIANT* v) override { return _attrs->GetItemByIndex(i, k, v); }
    STDMETHODIMP CopyAllItems(IMFAttributes* d) override { return _attrs->CopyAllItems(d); }

private:
    ComPtr<IMFAttributes> _attrs;
};

class Factory : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IClassFactory> {
public:
    STDMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        LogGuid(L"Factory::CreateInstance riid", riid, 0);
        if (outer) return CLASS_E_NOAGGREGATION;
        if (!ppv) return E_POINTER;
        // Frame Server path: IMFActivate (or IUnknown/IMFAttributes) -> activator -> source.
        if (riid == __uuidof(IMFActivate) || riid == __uuidof(IMFAttributes) || riid == __uuidof(IUnknown)) {
            ComPtr<CamNexoActivate> act;
            HRESULT hr = Microsoft::WRL::MakeAndInitialize<CamNexoActivate>(&act);
            if (FAILED(hr)) return hr;
            return act.CopyTo(riid, ppv);
        }
        // Direct path (used by the self test): the media source itself.
        ComPtr<CamNexoSource> src;
        HRESULT hr = Microsoft::WRL::MakeAndInitialize<CamNexoSource>(&src);
        if (FAILED(hr)) return hr;
        return src.CopyTo(riid, ppv);
    }
    STDMETHODIMP LockServer(BOOL) override { return S_OK; }
};

}  // namespace

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        wchar_t exe[MAX_PATH] = L"?";
        GetModuleFileNameW(nullptr, exe, MAX_PATH);
        Log(L"DllMain attach in %s\n", exe);
    } else if (reason == DLL_PROCESS_DETACH) {
        Log(L"DllMain detach\n");
    }
    return TRUE;
}

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv) {
    LogGuid(L"DllGetClassObject riid", riid, 0);
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (clsid != CLSID_CamNexoVCamSource) return CLASS_E_CLASSNOTAVAILABLE;
    auto factory = Make<Factory>();
    if (!factory) return E_OUTOFMEMORY;
    return factory.CopyTo(riid, ppv);
}

extern "C" HRESULT __stdcall DllCanUnloadNow() { return S_FALSE; }
