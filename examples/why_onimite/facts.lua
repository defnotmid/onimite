-- Every number on screen, with where it comes from. Nothing here is
-- estimated: renders are BENCHMARK.md "Full run (2026-10-12)" (fframes
-- main f962cd6, median of 3, 1920x1080, Ryzen 9 9900X3D + RX 9070 XT),
-- install sizes as M.SETUP says.

local M = {}

-- Wall seconds of the same video: fframes, then onimite (GPU).
M.RACE = {
  { "tiktok", 28.7, 6.34, "4.5×" },
  { "made_of_motion", 7.29, 2.13, "3.4×" },
  { "beta", 10.7, 4.09, "2.6×" },
  { "fframes_intro", 38.0, 19.3, "2.0×" },
  { "audio_announce", 9.49, 4.82, "2.0×" },
  { "shader_mode", 4.11, 3.04, "1.4×" },
}

-- The same rows: CPU seconds (user + sys) of tiktok, peak RSS of beta.
M.CPU = { example = "tiktok", fframes = 595, onimite = 2.4 }       -- s
M.MEMORY = { example = "beta", fframes = 28, onimite = 343 }        -- GB, MB

-- What is on disk before the first frame (2026-10-12, Linux x86_64, a
-- fresh install of each into an empty directory, `du -sh`, in MiB) and how
-- many packages it pulls in, subdependencies included. Each part: name, MB.
-- fframes 1.2.0: rustup's minimal stable toolchain; CARGO_HOME after
-- `cargo install cargo-fframes` and the build (the crates, cargo-fframes);
-- target/ after `cargo fframes new` + `cargo build --release` (Skia and
-- ffmpeg prebuilt); `cargo tree` counts the crates built for Linux. Its
-- README also lists system packages (x264, x265, opus, clang, ...): not
-- counted. Remotion 4.0.535: Node.js 24 LTS unpacked; node_modules of
-- remotion + @remotion/cli + react + react-dom (packages installed, from
-- package-lock.json); the Chrome Headless Shell it fetches to render.
M.SETUP = {
  { name = "fframes", deps = 311, kind = "crates",
    parts = { { "Rust toolchain", 593 }, { "crates", 312 }, { "first build", 2560 } } }, -- target/: 2.5G
  { name = "Remotion", deps = 251, kind = "packages",
    parts = { { "Node.js", 204 }, { "node_modules", 242 }, { "Chrome Headless Shell", 236 } } },
}
for _, s in ipairs(M.SETUP) do
  s.mb = 0
  for _, p in ipairs(s.parts) do s.mb = s.mb + p[2] end
end
-- onimite: the release as it ships, the stripped binary (odin build
-- -o:speed) and libSDL3 next to it, in MiB (the .tar.gz is 7.6). Nothing
-- else to install.
M.ONIMITE_MB = 17.6

-- "3.4 GB", "682 MB": a size in MiB as the film prints it.
function M.size(mb)
  return mb >= 1000 and string.format("%.1f GB", mb / 1024) or string.format("%.0f MB", mb)
end

return M
