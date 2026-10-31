#include "picture.h"

#include <algorithm>
#include <cstring>
#include <vector>

// See picture.h. Black bars are left to the caller (the canvas is cleared first).
void DrawCell(const Picture& p, int rot, bool cover, BYTE* canvasY, BYTE* canvasUv, int canvasW,
              int cx, int cy, int cw, int ch) {
    rot = (((rot % 360) + 360) % 360) / 90 * 90;
    const bool quarter = rot == 90 || rot == 270;
    const int dw = static_cast<int>(p.w), dh = static_cast<int>(p.h);
    const int rw = quarter ? dh : dw;  // size of the upright picture
    const int rh = quarter ? dw : dh;
    if (cw < 2 || ch < 2 || rw < 2 || rh < 2) return;

    double s;
    int fw, fh, ox, oy;
    double u0 = 0, v0 = 0;  // where the visible part starts inside the upright picture
    if (!cover) {
        s = std::min(static_cast<double>(cw) / rw, static_cast<double>(ch) / rh);
        fw = static_cast<int>(rw * s) & ~1;
        fh = static_cast<int>(rh * s) & ~1;
        ox = cx + (((cw - fw) / 2) & ~1);
        oy = cy + (((ch - fh) / 2) & ~1);
    } else {
        s = std::max(static_cast<double>(cw) / rw, static_cast<double>(ch) / rh);
        fw = cw;
        fh = ch;
        ox = cx;
        oy = cy;
        u0 = (rw - fw / s) / 2.0;
        v0 = (rh - fh / s) / 2.0;
    }
    if (fw < 2 || fh < 2) return;

    const BYTE* srcY = p.nv12.data();
    const BYTE* srcUv = srcY + static_cast<size_t>(dw) * dh;

    // Upright, same size and not cropped: plain row copies.
    if (rot == 0 && fw == dw && fh == dh && u0 < 0.5 && v0 < 0.5) {
        for (int y = 0; y < fh; ++y) memcpy(canvasY + static_cast<size_t>(oy + y) * canvasW + ox, srcY + static_cast<size_t>(y) * dw, fw);
        for (int y = 0; y < fh / 2; ++y) memcpy(canvasUv + static_cast<size_t>(oy / 2 + y) * canvasW + ox, srcUv + static_cast<size_t>(y) * dw, fw);
        return;
    }

    thread_local std::vector<int> colU, rowV;
    colU.resize(fw);
    rowV.resize(fh);
    for (int i = 0; i < fw; ++i) colU[i] = std::clamp(static_cast<int>(u0 + i / s), 0, rw - 1);
    for (int j = 0; j < fh; ++j) rowV[j] = std::clamp(static_cast<int>(v0 + j / s), 0, rh - 1);

    // Upright picture coordinate -> coordinate in the picture as it was decoded.
    auto toSource = [&](int u, int v, int& sx, int& sy) {
        switch (rot) {
            case 90:  sx = v;          sy = dh - 1 - u; break;
            case 180: sx = dw - 1 - u; sy = dh - 1 - v; break;
            case 270: sx = dw - 1 - v; sy = u;          break;
            default:  sx = u;          sy = v;          break;
        }
    };

    for (int j = 0; j < fh; ++j) {
        BYTE* out = canvasY + static_cast<size_t>(oy + j) * canvasW + ox;
        for (int i = 0; i < fw; ++i) {
            int sx, sy;
            toSource(colU[i], rowV[j], sx, sy);
            out[i] = srcY[static_cast<size_t>(sy) * dw + sx];
        }
    }
    for (int j = 0; j < fh / 2; ++j) {
        BYTE* out = canvasUv + static_cast<size_t>(oy / 2 + j) * canvasW + ox;
        for (int i = 0; i < fw / 2; ++i) {
            int sx, sy;
            toSource(colU[2 * i], rowV[2 * j], sx, sy);
            const BYTE* px = srcUv + static_cast<size_t>(sy / 2) * dw + (sx / 2) * 2;
            out[i * 2] = px[0];
            out[i * 2 + 1] = px[1];
        }
    }
}

