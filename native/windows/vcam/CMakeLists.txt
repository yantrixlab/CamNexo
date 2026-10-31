cmake_minimum_required(VERSION 3.20)
project(camnexo_vcam LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Static CRT: the source DLL is loaded by the Frame Server service, so it must not depend on a VC redistributable.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

# Media source loaded by the Windows Frame Server; produces an NV12 test pattern.
add_library(camnexo_vcam_source SHARED src/source.cpp src/source.def)
target_link_libraries(camnexo_vcam_source PRIVATE mfplat mfuuid mfsensorgroup ole32 runtimeobject)

# Registers the source COM class and creates the virtual camera for the current session.
add_executable(camnexo_vcam src/vcam_main.cpp)
target_link_libraries(camnexo_vcam PRIVATE mfplat mf mfuuid mfreadwrite mfsensorgroup ole32 shell32 advapi32)
