# Pitch region model

`PitchRegions.mlpackage` is an FP16 Core ML conversion of Spiideo's
SoccerNetChallenge2023 checkpoint, with sigmoid probabilities downsampled 4×.
Input: RGB 960×544, scaled by 1/255. Outputs: field, centre circle, penalty
areas, penalty arcs, goal areas, vertical goals. Camelot uses circle/area
regions only as user-reviewable starting alignments, not verified measurements.

Source and weights: https://github.com/Spiideo/soccersegcal
Conversion: `clients/ios/scripts/convert_pitch_model.py`.

MIT License

Copyright (c) 2023 Spiideo AB

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
