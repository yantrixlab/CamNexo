#pragma once
#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
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

// Loads onnxruntime.dll and the person-matting model that sit next to the program (in `dir`).
// Without them the picture is passed through untouched. On failure `why` says what is missing.
bool Init(const std::wstring& dir, std::string* why);
bool Available();

// Reads an image file (PNG, JPEG, BMP...) as top-down BGRA.
bool LoadImageBgra(const std::wstring& path, int* w, int* h, std::vector<BYTE>* bgra);

// Applies the effects to one camera's pictures. One instance per camera; call Process from one thread.
// The person mask is worked out on a helper thread of its own, so a slow moment in the model never
// holds up the picture: each picture is blended with the newest mask that is ready.
class Processor {
public:
    Processor() = default;
    ~Processor();
    Processor(const Processor&) = delete;
    Processor& operator=(const Processor&) = delete;

    // Returns the picture with the effects applied, or `in` itself when there is nothing to do.
    // `rotation` is how many degrees clockwise make the picture upright. With a background effect the
    // result is turned upright (Picture::upright) and limited to about Full HD to keep it fast.
    std::shared_ptr<const Picture> Process(const std::shared_ptr<const Picture>& in, int rotation,
                                           const EffectSettings& s);

    // Milliseconds the last Process call took, and the last model run took, for the log.
    double lastMs = 0;
    std::atomic<double> modelMs{0};

private:
    struct Mask {
        int w = 0, h = 0;
        std::vector<BYTE> a;  // 0..255
    };

    void StartWorker();
    void WorkerLoop();
    void Submit(const Picture& up);
    bool WaitForMask(int timeoutMs);
    void Blend(Picture& up, const EffectSettings& s, const Mask& mask);

    // helper thread and its mailbox
    std::thread _worker;
    std::mutex _m;
    std::condition_variable _cv;
    bool _stop = false;
    bool _hasInput = false;
    int _inW = 0, _inH = 0;
    std::vector<BYTE> _inRgb;

    // the newest mask
    std::mutex _maskMutex;
    Mask _mask;
    std::vector<float> _smooth;  // mask smoothed over time

    std::vector<BYTE> _bgY, _bgUv;  // the replacement picture at the current size
    std::wstring _bgPath;
    uint32_t _bgW = 0, _bgH = 0;
    bool _bgOk = false;
    std::vector<BYTE> _rgb;
};

// Brightness, contrast, saturation and warmth, in place on NV12.
void ApplyFilters(Picture& p, const EffectSettings& s);

}  // namespace fx
