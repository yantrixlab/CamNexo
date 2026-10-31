#pragma once
#include <guiddef.h>

// CLSID of the CamNexo virtual camera media source.
// {5E6B7C2A-3F0D-4B7A-9C41-2D8E6A1F0B53}
inline constexpr GUID CLSID_CamNexoVCamSource =
    {0x5e6b7c2a, 0x3f0d, 0x4b7a, {0x9c, 0x41, 0x2d, 0x8e, 0x6a, 0x1f, 0x0b, 0x53}};

#define CAMNEXO_VCAM_CLSID_STRING L"{5E6B7C2A-3F0D-4B7A-9C41-2D8E6A1F0B53}"
#define CAMNEXO_VCAM_NAME L"CamNexo"
#define CAMNEXO_VCAM_DLL L"camnexo_vcam_source.dll"
