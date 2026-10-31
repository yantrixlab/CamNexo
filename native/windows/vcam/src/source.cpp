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
#include <atomic>
#include <chrono>
#include <deque>
#include <mutex>
#include <thread>

#include "ids.h"

using Microsoft::WRL::ChainInterfaces;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;

namespace {

constexpr UINT32 kWidth = 1280;
constexpr UINT32 kHeight = 720;
constexpr UINT32 kFps = 30;
constexpr UINT32 kFrameBytes = kWidth * kHeight * 3 / 2;

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
void FillNv12(BYTE* dst, UINT64 frame) {
    static const BYTE Y[8] = {235, 210, 170, 145, 106, 81, 41, 16};
    static const BYTE U[8] = {128, 16, 166, 54, 202, 90, 240, 128};
    static const BYTE V[8] = {128, 146, 16, 34, 222, 240, 110, 128};
    const UINT shift = static_cast<UINT>((frame / 15) % 8);

    BYTE* yPlane = dst;
    for (UINT32 y = 0; y < kHeight; ++y) {
        for (UINT32 x = 0; x < kWidth; ++x) {
            yPlane[y * kWidth + x] = Y[(x * 8 / kWidth + shift) % 8];
        }
    }
    BYTE* uvPlane = dst + kWidth * kHeight;
    for (UINT32 y = 0; y < kHeight / 2; ++y) {
        for (UINT32 x = 0; x < kWidth / 2; ++x) {
            const UINT bar = (x * 2 * 8 / kWidth + shift) % 8;
            uvPlane[y * kWidth + x * 2] = U[bar];
            uvPlane[y * kWidth + x * 2 + 1] = V[bar];
        }
    }

    const UINT32 box = 96;
    const UINT32 bx = static_cast<UINT32>((frame * 8) % (kWidth - box)) & ~1u;
    const UINT32 by = (kHeight / 2 - box / 2) & ~1u;
    for (UINT32 y = by; y < by + box; ++y) {
        for (UINT32 x = bx; x < bx + box; ++x) yPlane[y * kWidth + x] = 235;
    }
    for (UINT32 y = by / 2; y < (by + box) / 2; ++y) {
        for (UINT32 x = bx; x < bx + box; x += 2) {
            uvPlane[y * kWidth + x] = 128;
            uvPlane[y * kWidth + x + 1] = 128;
        }
    }
}

void LogGuid(const wchar_t* what, REFGUID g, HRESULT hr) {
    wchar_t s[64] = L"?";
    StringFromGUID2(g, s, 64);
    Log(L"%s %s -> 0x%08lx\n", what, s, hr);
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

            ComPtr<IMFMediaBuffer> buffer;
            if (FAILED(MFCreateMemoryBuffer(kFrameBytes, &buffer))) continue;
            BYTE* data = nullptr;
            if (FAILED(buffer->Lock(&data, nullptr, nullptr))) continue;
            FillNv12(data, frame);
            buffer->Unlock();
            buffer->SetCurrentLength(kFrameBytes);

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

        ComPtr<IMFMediaType> type;
        hr = MFCreateMediaType(&type);
        if (FAILED(hr)) return hr;
        type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, kWidth, kHeight);
        MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, kFps, 1);
        MFSetAttributeRatio(type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
        type->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
        type->SetUINT32(MF_MT_DEFAULT_STRIDE, kWidth);
        type->SetUINT32(MF_MT_SAMPLE_SIZE, kFrameBytes);

        IMFMediaType* types[] = {type.Get()};
        hr = MFCreateStreamDescriptor(0, 1, types, &_descriptor);
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
    STDMETHODIMP SetMediaType(DWORD streamId, IMFMediaType*) override {
        Log(L"source SetMediaType(%lu)\n", streamId);
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
