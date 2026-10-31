// CamNexo virtual camera spike launcher.
//   camnexo_vcam register    (admin) copy the source DLL to %ProgramData%\CamNexo and register its COM class in HKLM
//   camnexo_vcam unregister  (admin) remove the COM registration
//   camnexo_vcam run         create the "CamNexo" virtual camera for this session; Enter removes it

#include <windows.h>
#include <shlobj.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfvirtualcamera.h>
#include <mfreadwrite.h>
#include <strmif.h>
#include <ks.h>
#include <ksproxy.h>

#include <cstdio>
#include <string>

#include "ids.h"

static std::wstring ProgramDataDir() {
    PWSTR p = nullptr;
    std::wstring dir;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_ProgramData, 0, nullptr, &p))) dir = p;
    CoTaskMemFree(p);
    return dir + L"\\CamNexo\\vcam";
}

static std::wstring ClsidKey() {
    return std::wstring(L"Software\\Classes\\CLSID\\") + CAMNEXO_VCAM_CLSID_STRING;
}

static int Register() {
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring src(exe);
    src = src.substr(0, src.find_last_of(L'\\') + 1) + CAMNEXO_VCAM_DLL;

    std::wstring dir = ProgramDataDir();
    SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
    std::wstring dst = dir + L"\\" + CAMNEXO_VCAM_DLL;
    if (!CopyFileW(src.c_str(), dst.c_str(), FALSE)) {
        fwprintf(stderr, L"Copy %s -> %s failed (%lu). Run as administrator?\n", src.c_str(), dst.c_str(), GetLastError());
        return 1;
    }

    HKEY key;
    std::wstring inproc = ClsidKey() + L"\\InprocServer32";
    LSTATUS st = RegCreateKeyExW(HKEY_LOCAL_MACHINE, inproc.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr);
    if (st != ERROR_SUCCESS) {
        fwprintf(stderr, L"Registry write failed (%ld). Run as administrator.\n", st);
        return 1;
    }
    RegSetValueExW(key, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE*>(dst.c_str()),
                   static_cast<DWORD>((dst.size() + 1) * sizeof(wchar_t)));
    const wchar_t model[] = L"Both";
    RegSetValueExW(key, L"ThreadingModel", 0, REG_SZ, reinterpret_cast<const BYTE*>(model), sizeof(model));
    RegCloseKey(key);
    wprintf(L"Registered %s -> %s\n", CAMNEXO_VCAM_CLSID_STRING, dst.c_str());
    return 0;
}

static int Unregister() {
    LSTATUS st = RegDeleteTreeW(HKEY_LOCAL_MACHINE, ClsidKey().c_str());
    if (st != ERROR_SUCCESS && st != ERROR_FILE_NOT_FOUND) {
        fwprintf(stderr, L"Registry delete failed (%ld). Run as administrator.\n", st);
        return 1;
    }
    wprintf(L"Unregistered.\n");
    return 0;
}

static int Run(int seconds) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) { fwprintf(stderr, L"CoInitializeEx 0x%08lx\n", hr); return 1; }
    hr = MFStartup(MF_VERSION);
    if (FAILED(hr)) { fwprintf(stderr, L"MFStartup 0x%08lx\n", hr); return 1; }

    IMFVirtualCamera* cam = nullptr;
    hr = MFCreateVirtualCamera(MFVirtualCameraType_SoftwareCameraSource, MFVirtualCameraLifetime_Session,
                               MFVirtualCameraAccess_CurrentUser, CAMNEXO_VCAM_NAME, CAMNEXO_VCAM_CLSID_STRING,
                               nullptr, 0, &cam);
    if (FAILED(hr)) { fwprintf(stderr, L"MFCreateVirtualCamera 0x%08lx\n", hr); return 1; }

    hr = cam->Start(nullptr);
    if (FAILED(hr)) {
        fwprintf(stderr, L"IMFVirtualCamera::Start 0x%08lx\n", hr);
        cam->Remove();
        cam->Release();
        return 1;
    }
    wprintf(L"Virtual camera \"%s\" is live. Pick it in Zoom/Meet/OBS/Camera app. Press Enter to remove it.\n",
            CAMNEXO_VCAM_NAME);
    if (seconds > 0) Sleep(seconds * 1000);  // unattended mode: `run <seconds>`
    else getchar();

    cam->Stop();
    cam->Remove();
    cam->Shutdown();
    cam->Release();
    MFShutdown();
    CoUninitialize();
    return 0;
}

// Loads the registered source in this process, checks the interfaces the Frame Server relies on, and pulls frames.
static int SelfTest() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);

    IMFMediaSourceEx* src = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_CamNexoVCamSource, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&src));
    wprintf(L"CoCreateInstance(IMFMediaSourceEx)        0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    auto probe = [&](const wchar_t* name, REFIID iid) {
        void* p = nullptr;
        HRESULT h = src->QueryInterface(iid, &p);
        wprintf(L"source QI %-30s 0x%08lx\n", name, h);
        if (p) static_cast<IUnknown*>(p)->Release();
    };
    probe(L"IMFMediaSource", __uuidof(IMFMediaSource));
    probe(L"IMFMediaEventGenerator", __uuidof(IMFMediaEventGenerator));
    probe(L"IMFGetService", __uuidof(IMFGetService));
    probe(L"IKsControl", __uuidof(IKsControl));
    probe(L"IMFSampleAllocatorControl", __uuidof(IMFSampleAllocatorControl));

    IMFPresentationDescriptor* pd = nullptr;
    hr = src->CreatePresentationDescriptor(&pd);
    wprintf(L"CreatePresentationDescriptor              0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    PROPVARIANT empty;
    PropVariantInit(&empty);
    hr = src->Start(pd, nullptr, &empty);
    wprintf(L"Start                                     0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    IMFMediaStream* stream = nullptr;
    for (int i = 0; i < 4 && !stream; ++i) {
        IMFMediaEvent* ev = nullptr;
        if (FAILED(src->GetEvent(0, &ev))) break;
        MediaEventType type = 0;
        ev->GetType(&type);
        wprintf(L"source event %lu\n", type);
        if (type == MENewStream) {
            PROPVARIANT v;
            PropVariantInit(&v);
            ev->GetValue(&v);
            if (v.vt == VT_UNKNOWN && v.punkVal) v.punkVal->QueryInterface(IID_PPV_ARGS(&stream));
            PropVariantClear(&v);
        }
        ev->Release();
    }
    if (!stream) { wprintf(L"no stream from MENewStream\n"); return 1; }

    IMFMediaStream2* s2 = nullptr;
    hr = stream->QueryInterface(IID_PPV_ARGS(&s2));
    wprintf(L"stream QI IMFMediaStream2                 0x%08lx\n", hr);
    for (int i = 0; i < 5; ++i) stream->RequestSample(nullptr);
    int got = 0;
    while (got < 5) {
        IMFMediaEvent* ev = nullptr;
        if (FAILED(stream->GetEvent(0, &ev))) break;
        MediaEventType type = 0;
        ev->GetType(&type);
        if (type == MEMediaSample) {
            PROPVARIANT v;
            PropVariantInit(&v);
            ev->GetValue(&v);
            IMFSample* s = nullptr;
            DWORD len = 0;
            if (v.vt == VT_UNKNOWN && SUCCEEDED(v.punkVal->QueryInterface(IID_PPV_ARGS(&s)))) {
                s->GetTotalLength(&len);
                s->Release();
            }
            wprintf(L"sample %d: %lu bytes\n", got, len);
            PropVariantClear(&v);
            ++got;
        } else {
            wprintf(L"stream event %lu\n", type);
        }
        ev->Release();
    }
    src->Stop();
    src->Shutdown();
    src->Release();
    MFShutdown();
    wprintf(L"selftest OK\n");
    return 0;
}

// Enumerates video capture devices like a meeting app does, then reads frames from the CamNexo one.
static int Probe(const wchar_t* match) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);

    SYSTEMTIME st;
    GetLocalTime(&st);
    wprintf(L"probe start %02d:%02d:%02d.%03d\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    IMFAttributes* q = nullptr;
    MFCreateAttributes(&q, 1);
    q->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    IMFActivate** devs = nullptr;
    UINT32 n = 0;
    HRESULT hr = MFEnumDeviceSources(q, &devs, &n);
    wprintf(L"MFEnumDeviceSources 0x%08lx, %u device(s)\n", hr, n);
    IMFActivate* ours = nullptr;
    for (UINT32 i = 0; i < n; ++i) {
        WCHAR* name = nullptr;
        UINT32 len = 0;
        devs[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &len);
        wprintf(L"  [%u] %s\n", i, name ? name : L"?");
        if (name && wcsstr(name, match)) ours = devs[i];
        CoTaskMemFree(name);
    }
    if (!ours) { wprintf(L"CamNexo not found. Is `camnexo_vcam run` active?\n"); return 1; }

    IMFMediaSource* source = nullptr;
    hr = ours->ActivateObject(IID_PPV_ARGS(&source));
    wprintf(L"ActivateObject                0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    IMFSourceReader* reader = nullptr;
    hr = MFCreateSourceReaderFromMediaSource(source, nullptr, &reader);
    wprintf(L"MFCreateSourceReader          0x%08lx\n", hr);
    if (FAILED(hr)) return 1;

    int frames = 0;
    for (int i = 0; i < 60 && frames < 10; ++i) {
        DWORD flags = 0;
        LONGLONG ts = 0;
        IMFSample* s = nullptr;
        hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, &flags, &ts, &s);
        if (FAILED(hr)) {
            GetLocalTime(&st);
            wprintf(L"ReadSample failed 0x%08lx at %02d:%02d:%02d.%03d\n", hr, st.wHour, st.wMinute, st.wSecond,
                    st.wMilliseconds);
            break;
        }
        if (s) {
            DWORD len = 0;
            s->GetTotalLength(&len);
            wprintf(L"frame %d  ts=%lld ms  %lu bytes\n", frames, ts / 10000, len);
            s->Release();
            ++frames;
        } else if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            break;
        }
    }
    wprintf(frames ? L"probe OK: %d frames\n" : L"probe FAILED: no frames\n", frames);
    reader->Release();
    source->Shutdown();
    source->Release();
    return frames ? 0 : 1;
}

int wmain(int argc, wchar_t** argv) {
    std::wstring cmd = argc > 1 ? argv[1] : L"";
    if (cmd == L"register") return Register();
    if (cmd == L"unregister") return Unregister();
    if (cmd == L"run") return Run(argc > 2 ? _wtoi(argv[2]) : 0);
    if (cmd == L"selftest") return SelfTest();
    if (cmd == L"probe") return Probe(argc > 2 ? argv[2] : CAMNEXO_VCAM_NAME);
    fwprintf(stderr, L"usage: camnexo_vcam register | unregister | run | selftest\n");
    return 2;
}
