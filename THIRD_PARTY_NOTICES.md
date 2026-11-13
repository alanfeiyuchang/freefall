# Third-party notices

Everything not listed here was written for Freefall and is covered by [LICENSE](LICENSE).

## Assets shipped in the app

### Sound effects — CC BY 4.0

By **Huggy13ear** on freesound.org, licensed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
Details and the changes made are in `Freefall/Resources/Audio/CREDITS.txt`.

| File | Original |
|---|---|
| `wind_rush.m4a` | ["wind 2"](https://freesound.org/people/Huggy13ear/sounds/138970/) |
| `chute_open.m4a` | ["parachute 2"](https://freesound.org/people/Huggy13ear/sounds/138976/) |
| `canopy_flap.m4a` | ["nylon flapping 1"](https://freesound.org/people/Huggy13ear/sounds/138979/) |

Changes: converted to AAC, loudness-normalised, ends cross-faded into loops; played back with
speed-dependent gain, pitch and filtering.

### Glove model — Apple sample code license

`Freefall/Resources/Gloves/` is converted (recoloured, decimated, textures resized) by
`tools/gloves/convert_gloves.py` from the glove model in Apple's sample code
["Animating hand models in visionOS"](https://developer.apple.com/documentation/visionos/animating-hand-models-in-visionos).
Copyright © 2025 Apple Inc.; the full license text is in
`Freefall/Resources/Gloves/LICENSE-Apple-sample.txt`.

### App icon

Generated locally with [FLUX.2 [klein] 4B](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B)
(Apache License 2.0) and composited by hand. Not covered by the MIT license — see LICENSE.

## Code adapted from, or written after, other projects

### MetalSplatter — MIT

The render loop skeleton in `Freefall/ImmersiveRenderer.swift` (frame timing, drawables, the
renderer task executor) comes, through the author's earlier project Bubble Dream, from the
visionOS sample in [MetalSplatter](https://github.com/scier/MetalSplatter).

```
MIT License
Copyright (c) 2026 Sean Cier
```

### UnrealEngineSkyAtmosphere — MIT

`Freefall/Shaders/Atmosphere.h` implements Hillaire 2020, "A Scalable and Production Ready Sky
and Atmosphere Rendering Technique", following the reference implementation
[sebh/UnrealEngineSkyAtmosphere](https://github.com/sebh/UnrealEngineSkyAtmosphere).

```
MIT License
Copyright (c) 2020 Epic Games, Inc.
```

### TileableVolumeNoise — MIT

The tileable cloud noise in `Freefall/Shaders/Noise.h` follows
[sebh/TileableVolumeNoise](https://github.com/sebh/TileableVolumeNoise) and Schneider,
"Real-Time Volumetric Cloudscapes" (GPU Pro 7).

```
The MIT License (MIT)
Copyright (c) 2017 Sébastien Hillaire
```

The MIT License text for the three entries above:

```
Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Techniques (credited, no code copied)

- Volumetric clouds after Andrew Schneider's Nubis talks (Guerrilla Games) — `Freefall/Shaders/Clouds.h`.
- Eroded fbm after Inigo Quilez's articles on noise derivatives — `tEroded` in `Freefall/Shaders/TerrainField.h`.
- `pcg3d` hash from Jarzynski & Olano, "Hash Functions for GPU Rendering" (JCGT 2020) — `Freefall/Shaders/Noise.h`.
