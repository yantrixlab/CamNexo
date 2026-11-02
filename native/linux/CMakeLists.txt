cmake_minimum_required(VERSION 3.16)
project(camnexo_linux CXX)

# The CamNexo receiver for Linux. The picture and effects code is shared with the Windows build
# (native/windows/vcam/src); only the receiver itself (sockets, FFmpeg decoding, Avahi, v4l2loopback)
# is written for Linux.
#
#   sudo apt install build-essential cmake pkg-config libavcodec-dev libavutil-dev libavahi-client-dev
#   cmake -S native/linux -B native/linux/build -DCMAKE_BUILD_TYPE=Release
#   cmake --build native/linux/build

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(Threads REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET libavcodec libavutil)
pkg_check_modules(AVAHI REQUIRED IMPORTED_TARGET avahi-client)

set(SHARED ${CMAKE_CURRENT_SOURCE_DIR}/../windows/vcam)

add_executable(camnexo_receiver
  receiver/receiver_linux.cpp
  ${SHARED}/src/draw.cpp
  ${SHARED}/src/effects.cpp)
target_include_directories(camnexo_receiver PRIVATE
  ${SHARED}/src
  ${SHARED}/third_party/onnxruntime/include
  ${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb)
target_compile_options(camnexo_receiver PRIVATE -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(camnexo_receiver PRIVATE PkgConfig::FFMPEG PkgConfig::AVAHI Threads::Threads ${CMAKE_DL_LIBS})

install(TARGETS camnexo_receiver RUNTIME DESTINATION lib/camnexo)

# Packages carry their own FFmpeg libraries next to the receiver (build-ffmpeg.sh), in lib/. DT_RPATH (not
# RUNPATH) is used so that libavcodec finds libavutil there too.
option(CAMNEXO_BUNDLED_LIBS "Look for the FFmpeg libraries in lib/ next to the receiver" OFF)
if(CAMNEXO_BUNDLED_LIBS)
  set_target_properties(camnexo_receiver PROPERTIES
    BUILD_WITH_INSTALL_RPATH ON
    INSTALL_RPATH "\$ORIGIN/lib")
  target_link_options(camnexo_receiver PRIVATE -Wl,--disable-new-dtags)
endif()
