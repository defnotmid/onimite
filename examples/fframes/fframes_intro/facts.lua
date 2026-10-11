-- Every measured number that appears on screen, in one place (facts.rs).
-- They come from fframes' own runs (render-bench/vs-remotion and its CLI).

return {
  -- Release shown on the opening and closing screens (the crate's version).
  RELEASE_LABEL = "v1.2.0",
  -- Lines of Rust in fframes plus its SVG renderer fork, svgr.
  LINES_OF_RUST = 89372,
  -- Frames in this video.
  FRAMES = 7650,
  -- Wall-clock seconds for this video on Apple M5 Max (Skia on Metal, libx264, with audio).
  RENDER_SECONDS = 79.6,
  -- Complete H.264 MP4 export seconds for 300 frames at 3840x2160.
  BENCH_REMOTION_S = 121.1321,
  BENCH_FFRAMES_S = 4.074223,
  BENCH_FFRAMES_CPU_S = 69.74039,
  BENCH_REMOTION_LABEL = "REMOTION 4.0",
  BENCH_FFRAMES_LABEL = "FFRAMES · SKIA ON METAL",
  BENCH_NOTE = "M5 MAX · REMOTION 4.0.529 · SERIAL · H.264 MP4 · MEDIANS",
}
