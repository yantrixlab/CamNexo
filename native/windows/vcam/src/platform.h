#pragma once
// What the shared picture and effects code needs from the operating system: the byte type and the
// type used for file paths (wide strings on Windows, UTF-8 on Linux).
#include <cstdint>
#include <string>

#ifdef _WIN32
#include <windows.h>
using FxString = std::wstring;
#else
using BYTE = uint8_t;
using FxString = std::string;
#endif
