#pragma once
#include <cstdint>
#include <vector>

#include "platform.h"

// One decoded picture: tightly packed NV12 (all Y rows, then the interleaved UV rows).
struct Picture {
    uint32_t w = 0;
    uint32_t h = 0;
    uint64_t ts100ns = 0;
    // true when the picture has already been turned upright (effects do that); the compositor
    // then does not rotate it again.
    bool upright = false;
    std::vector<BYTE> nv12;
};

// Draws a picture, upright (rotated clockwise by rot degrees), into a rectangle of an NV12 canvas
// (nearest neighbour). cover = fill the rectangle and crop the overflow around the centre;
// otherwise the whole picture is fitted inside it. canvasY / canvasUv are the two planes, both
// canvasW bytes per row. The rectangle must be even-aligned and inside the canvas.
void DrawCell(const Picture& p, int rot, bool cover, BYTE* canvasY, BYTE* canvasUv, int canvasW,
              int cx, int cy, int cw, int ch);
