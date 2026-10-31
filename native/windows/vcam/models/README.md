# Models

`modnet.onnx` is MODNet (Ke et al., "Is a Green Screen Really Necessary for Real-Time Portrait Matting?",
Apache License 2.0, https://github.com/ZHKKKe/MODNet), converted to ONNX and published by Xenova on Hugging Face as
`Xenova/modnet` (Apache-2.0). It takes an RGB picture (float, channels first, scaled to -1..1, height and width
in steps of 32) and returns a person matte of the same size.

It is used for background blur and background replacement in the receiver (`src/effects.cpp`), at 256 x 160
(or 160 x 256 for tall pictures). It replaces the MediaPipe Selfie Segmentation models used in the first version,
which let parts of the room behind the person through.
