# Models

`selfie_segmentation.onnx` is the MediaPipe Selfie Segmentation model from Google (Apache License 2.0),
converted to ONNX and published by the `onnx-community` project on Hugging Face as
`onnx-community/mediapipe_selfie_segmentation-web` (Apache-2.0). It takes a 256 x 256 RGB picture
(uint8, NHWC) and returns a 256 x 256 person mask.

It is used for background blur and background replacement in the receiver (`src/effects.cpp`).

`selfie_segmentation_landscape.onnx` is the 16:9 variant (`onnx-community/mediapipe_selfie_segmentation_landscape`,
Apache-2.0): 256 x 144 float RGB (0..1, channels first) in, 256 x 144 person mask out. It is used for wide pictures;
the square model above is used for tall (portrait) pictures.
