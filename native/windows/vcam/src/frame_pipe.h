#pragma once
#include <cstdint>

// Frames travel from the receiver (user session) to the virtual camera source (Frame Server,
// session 0) over a named pipe: Local\ shared memory would not be visible across sessions.
//
// Stream layout: repeated { FramePipeHeader, width*height*3/2 bytes of NV12 }.

#define CAMNEXO_FRAME_PIPE L"\\\\.\\pipe\\camnexo-frames"

// A second, small stream for the desktop window's preview: always kPreviewWidth x kPreviewHeight (the composed layout),
// RGBA (4 bytes per pixel), about 15 per second. The window does not have to touch full-size frames.
#define CAMNEXO_PREVIEW_PIPE L"\\\\.\\pipe\\camnexo-preview"

constexpr uint32_t kFramePipeMagic = 0x46584E43;  // "CNXF"

// Frames on the camera pipe are NV12 and can be any size up to 4K; the header says which.
constexpr uint32_t kMaxFrameWidth = 3840;
constexpr uint32_t kMaxFrameHeight = 2160;
constexpr uint32_t kPreviewWidth = 960;
constexpr uint32_t kPreviewHeight = 540;

// Size used before a phone has said anything (test pattern, default format).
constexpr uint32_t kOutWidth = 1280;
constexpr uint32_t kOutHeight = 720;
constexpr uint32_t kOutFrameBytes = kOutWidth * kOutHeight * 3 / 2;

#pragma pack(push, 1)
struct FramePipeHeader {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t reserved;
    uint64_t timestamp100ns;
};
#pragma pack(pop)

static_assert(sizeof(FramePipeHeader) == 24, "pipe header layout");
