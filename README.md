# Metal Meshlet Benchmark

This project is turning the Metal by Example meshlet culling sample into a small Metal performance bench for comparing classic indexed VS/PS, vertex pulling, and Metal mesh/object shader submission paths.

The current scene loads `MetalMeshletCulling/Resources/kitten.obj` at runtime, builds GPU buffers with meshoptimizer options, and renders a 20x20x20 grid of 8000 instances. The interactive app exposes render path, culling, meshoptimizer, and meshlet composition controls through a simple HUD.

## Current Benchmark Surface

- Render paths: `Indexed`, `Pulling`, `Meshlet`
- VS/PS culling modes: `No Cull`, `CPU Frustum`, `GPU Frustum`, `GPU HiZ`
- Meshlet culling modes: `No Cull`, `Frustum`, `Full`, `Full+HiZ`
- Meshoptimizer presets used by the automated run:
  - `raw`: no VS/PS preprocessing; Meshlet mode still builds meshlets because it has to
  - `remap`: `generateVertexRemap` + remap index/vertex buffers
  - `all_on`: remap + vertex cache + overdraw + vertex fetch, plus `Optimize Meshlet` in Meshlet mode
- Meshlet composition default: `128 vertices / 256 triangles`
- Hi-Z uses the previous frame depth pyramid; first frame after resize or mode change falls back to non-Hi-Z behavior.

## Build

```sh
xcodebuild \
  -project MetalMeshletCulling.xcodeproj \
  -scheme MetalMeshletCulling \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  build
```

`meshletgen` is deprecated and is not part of the benchmark path.

## Automated Run

```sh
MBE_BENCHMARK=1 \
MBE_BENCHMARK_WARMUP=30 \
MBE_BENCHMARK_FRAMES=60 \
MBE_BENCHMARK_OUTPUT="$PWD/benchmark_results.csv" \
build/DerivedData/Build/Products/Debug/MetalMeshletCulling.app/Contents/MacOS/MetalMeshletCulling
```

Useful environment variables:

- `MBE_BENCHMARK=1`: run all benchmark cases and quit.
- `MBE_BENCHMARK_WARMUP`: warmup frames per case.
- `MBE_BENCHMARK_FRAMES`: measured frames per case.
- `MBE_BENCHMARK_FPS`: MTKView display-link target while benchmarking; default is `240`.
- `MBE_BENCHMARK_OUTPUT`: CSV output path.

## Latest Local Results

Run date: 2026-05-04. Build: Debug. Resolution: `1600x1200`. Sampling: 30 warmup frames + 60 measured frames per case. The tables report average GPU frame time only. Raw per-frame samples are in `benchmark_results.csv`.

Test machine:

- MacBook Air `Mac17,3`, model `MDHK4CH/A`
- Apple M5, 10 CPU cores: 4 Super cores + 6 Efficiency cores
- Apple M5 GPU, 10 cores
- Unified memory: 24 GB
- Built-in display: 2560x1664 Retina
- macOS 26.4.1, build `25E253`
- Xcode 26.4.1, build `17E202`
- Metal support: Metal 4

Test scene:

- Source model: `kitten.obj`
- Single imported model: 14856 vertices, 86832 indices, 28944 triangles
- Meshlet default composition: 128 vertices / 256 triangles
- Meshlets per model at the default composition: 141
- Instance grid: 20x20x20 = 8000 instances
- No-cull logical workload: 8000/8000 instances, 231552000 triangles per frame
- Current static-camera CPU frustum result: 4358/8000 instances, 126137952 triangles per frame

`GPU Frustum` for VS/PS uses compute compaction + indirect draw. Meshlet mode has one object-shader `Frustum` variant, so that value is repeated in the two frustum comparison rows below. `Full` and `Full+HiZ` are Meshlet-only normal-cone paths, so they do not have direct VS/PS equivalents.

### raw (obj index order)

| Culling setup | Indexed GPU ms | Pulling GPU ms | Meshlet GPU ms |
| --- | ---: | ---: | ---: |
| No Cull | 127.46 | 131.23 | 75.69 |
| Frustum, VS/PS CPU direct | 75.97 | 78.09 | 41.85 |
| Frustum, VS/PS GPU indirect | 77.81 | 79.60 | 41.85 |
| Meshlet Full cone | - | - | 32.33 |
| HiZ | 70.10 | 71.98 | 13.52 |

### remap (meshoptimizer vertex+index remap)

| Culling setup | Indexed GPU ms | Pulling GPU ms | Meshlet GPU ms |
| --- | ---: | ---: | ---: |
| No Cull | 127.61 | 131.22 | 75.76 |
| Frustum, VS/PS CPU direct | 76.20 | 78.04 | 41.78 |
| Frustum, VS/PS GPU indirect | 77.80 | 79.63 | 41.78 |
| Meshlet Full cone | - | - | 32.43 |
| HiZ | 70.25 | 72.02 | 13.53 |


### all_on (all meshoptimizer option)

| Culling setup | Indexed GPU ms | Pulling GPU ms | Meshlet GPU ms |
| --- | ---: | ---: | ---: |
| No Cull | 47.55 | 126.71 | 73.75 |
| Frustum, VS/PS CPU direct | 28.77 | 72.09 | 40.89 |
| Frustum, VS/PS GPU indirect | 29.18 | 72.44 | 40.89 |
| Meshlet Full cone | - | - | 31.69 |
| HiZ | 27.03 | 68.26 | 13.39 |


## Conclusions And Insights

This run is useful because the deltas are large enough to show that the harness is measuring the right kinds of changes. It is not a final architecture verdict yet, but it gives a good first map of where the interesting paths are.

Main conclusions:

- Indexed VS/PS is extremely sensitive to meshoptimizer preprocessing. `Indexed / No Cull / all_on` is `47.55 ms`, down from `127.46 ms` raw, a `2.68x` speedup. The same pattern holds with CPU frustum culling: `75.97 ms` raw to `28.77 ms` all_on, a `2.64x` speedup.
- `remap` alone does almost nothing for this model. The big indexed win comes from the full sequence: vertex cache, overdraw, and vertex fetch optimization after remap.
- Current vertex pulling is not benefiting from the optimized indexed layout in the same way. `Pulling / No Cull` only improves from `131.23 ms` raw to `126.71 ms` all_on. That makes sense for this first pulling path: it is submitted as non-indexed `drawPrimitives` over `indexCount`, then manually fetches the index and vertex, so it does not get the same indexed post-transform reuse as `drawIndexedPrimitives`.
- Meshlet no-cull is a strong baseline against raw indexed drawing: `75.69 ms` vs `127.46 ms`. Against fully optimized indexed drawing, though, meshlet no-cull loses: `73.75 ms` vs `47.55 ms`. So in this scene, mesh shaders need culling value to beat a well-optimized indexed path.
- Meshlet culling gives clear staged wins. In raw meshlet mode: no-cull `75.69 ms`, frustum `41.85 ms`, full cone culling `32.33 ms`, and `Full+HiZ` `13.52 ms`.
- Hi-Z is much more impactful at meshlet granularity than per-instance VS/PS granularity in this scene. Indexed GPU HiZ improves over GPU Frustum from `77.81 ms` to `70.10 ms` raw, while Meshlet Full+HiZ improves over Full from `32.33 ms` to `13.52 ms`.
- VS/PS GPU frustum indirect is slightly slower than CPU frustum direct for this static 8000-instance scene: Indexed raw `77.81 ms` vs `75.97 ms`, Pulling raw `79.60 ms` vs `78.09 ms`. That is expected while the CPU culling work is small and the GPU path pays compute compaction plus indirect draw overhead. The GPU path is still valuable because it lets us benchmark indirect draw and should scale differently for larger object counts or CPU-bound scenes.
- The current fastest case is `Meshlet / Full+HiZ / all_on` at `13.39 ms`. The fastest VS/PS case is `Indexed / GPU HiZ / all_on` at `27.03 ms`.

Working hypotheses for the next benchmark rounds:

- For VS/PS, focus on the fully optimized indexed baseline first; raw indexed is useful diagnostically but too unfair as a production comparison.
- For vertex pulling, test split position/normal/UV buffers and alternative layouts. The current interleaved manual fetch path is mostly a stress test for manual indexing, not proof that all vertex pulling designs are bad on Apple GPUs.
- For mesh shaders, keep no-cull in every run. It is the clean way to separate mesh shader submission/expansion cost from object-shader culling wins.
- Hi-Z needs correctness stress tests with moving cameras, changing visibility, and more varied occluders. This run uses previous-frame Hi-Z with a static camera, which is the friendliest possible condition.
- The next useful scenes are a larger continuous mesh and a high-occlusion scene. The current 8000 duplicated kitten grid is great for stress, but it overrepresents repeated small-mesh instance behavior.

Treat these numbers as an initial local baseline rather than final conclusions. The app currently runs a Debug build through the window system, and the scene is intentionally a stress case with many duplicated small meshes.
