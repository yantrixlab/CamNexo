#pragma once
#include <memory>
#include <string>
#include <vector>

#include "picture.h"

// What the desktop app asked for on one camera.
struct EffectSettings {
    int mode = 0;             // 0 none, 1 blur the background, 2 replace the background
    int blur = 60;            // 0..100, how strong the blur is
    std::wstring background;  // image file for mode 2
    int brightness = 0;       // -100..100
    int contrast = 0;         // -100..100
    int saturation = 0;       // -100..100
    int warmth = 0;           // -100..100 (negative is cooler)

    bool filtersActive() const { return brightness || contrast || saturation || warmth; }
    bool active() const { return mode != 0 || filtersActive(); }
};

namespace fx {

// Loads onnxruntime.dll and the person-segmentation model that sit next to the program (in `dir`).
// Without them the picture is passed through untouched. On failure `why` says what is missing.
bool Init(const std::wstring& dir, std::string* why);
bool Available();

// Reads an image file (PNG, JPEG, BMP...) as top-down BGRA.
bool LoadImageBgra(const std::wstring& path, int* w, int* h, std::vector<BYTE>* bgra);

// Applies the effects to one camera's pictures. One instance per camera; use it from one thread.
class Processor {
public:
    // Returns the picture with the effects applied, or `in` itself when there is nothing to do.
    // `rotation` is how many degrees clockwise make the picture upright. With a background effect the
    // result is turned upright (Picture::upright) and limited to about Full HD to keep it fast.
    std::shared_ptr<const Picture> Process(const std::shared_ptr<const Picture>& in, int rotation,
                                           const EffectSettings& s);

    // Milliseconds the last Process call took, for the log.
    double lastMs = 0;

private:
    bool UpdateMask(const Picture& up);
    void Blend(Picture& up, const EffectSettings& s);

    std::vector<float> _mask;       // person mask, smoothed over time
    int _mw = 256, _mh = 256;       // its size (256 x 144 for wide pictures, 256 x 256 for tall ones)
    std::vector<BYTE> _mask8;       // the same, 0..255
    std::vector<BYTE> _bgY, _bgUv;  // the replacement picture at the current size
    std::wstring _bgPath;
    uint32_t _bgW = 0, _bgH = 0;
    bool _bgOk = false;
    std::vector<BYTE> _rgb;
};

// Brightness, contrast, saturation and warmth, in place on NV12.
void ApplyFilters(Picture& p, const EffectSettings& s);

}  // namespace fx
