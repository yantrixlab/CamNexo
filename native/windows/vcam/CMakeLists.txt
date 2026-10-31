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

# Desktop receiver: phone TCP stream -> H.264 decode -> frame pipe -> virtual camera.
# Background effects (blur, replacement, filters) live in effects.cpp. They load onnxruntime.dll at run
# time (see third_party/onnxruntime), so only the header is needed to build.
add_executable(camnexo_receiver src/receiver_main.cpp src/draw.cpp src/effects.cpp)
target_include_directories(camnexo_receiver PRIVATE third_party/onnxruntime/include)
target_link_libraries(camnexo_receiver PRIVATE ws2_32 mfplat mf mfuuid wmcodecdspuuid strmiids ole32 advapi32 dnsapi windowscodecs)

# Next to the receiver: the person-matting model, and onnxruntime.dll when fetch-onnxruntime.ps1 has run.
add_custom_command(TARGET camnexo_receiver POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:camnexo_receiver>/models"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/models/modnet.onnx" "$<TARGET_FILE_DIR:camnexo_receiver>/models/"
    COMMAND ${CMAKE_COMMAND} -DSRC="${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime/bin" -DDST="$<TARGET_FILE_DIR:camnexo_receiver>"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/copy_onnxruntime.cmake")

# Registers the source COM class and creates the virtual camera for the current session.
add_executable(camnexo_vcam src/vcam_main.cpp)
target_link_libraries(camnexo_vcam PRIVATE mfplat mf mfuuid mfreadwrite mfsensorgroup ole32 shell32 advapi32)
