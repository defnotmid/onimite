-- The benchmark's numbers for the films, from bench/facts.json: `tools/bench.sh
-- facts` measures them on each release and `tools/bench.sh setup` adds the
-- installs, so none is typed here or in a film. A film in examples/<name>/
-- loads it with dofile("../../bench/facts.lua").
local fh = assert(io.open(SCRIPT_DIR .. "/../../bench/facts.json"), "no bench/facts.json: run tools/bench.sh facts")
local F = json_decode(fh:read("a"))
fh:close()
assert(#F.setup > 0, "bench/facts.json has no setup: run tools/bench.sh setup")
assert(F.race.compared > 0, "bench/facts.json has no race: run tools/bench.sh facts")

local B = { measured = F.measured }

-- The compared race rows, fastest first: name, fframes' and onimite's wall
-- seconds, the speed-up (fframes' time over onimite's), CPU seconds and
-- peak RSS bytes ({ fframes, onimite }).
B.race = {}
for _, r in ipairs(F.race.rows) do
  if r.speedup then
    B.race[#B.race + 1] = { name = r.name, fframes = r.fframes.wall_s, onimite = r.onimite.wall_s, speedup = r.speedup,
      cpu = { r.fframes.cpu_s, r.onimite.cpu_s }, rss = { r.fframes.rss_bytes, r.onimite.rss_bytes } }
  end
end
table.sort(B.race, function(a, b) return a.speedup > b.speedup end)
B.compared, B.faster = F.race.compared, F.race.onimite_faster
-- fframes' wins, its biggest first.
B.losses = {}
for i = #B.race, 1, -1 do
  if B.race[i].speedup < 1 then B.losses[#B.losses + 1] = B.race[i] end
end
-- The rows where onimite needs the smallest share of fframes' CPU time and
-- of its memory: the example, both sides (CPU seconds; memory in GB for
-- fframes and MB for onimite, binary units as the system reports them),
-- onimite's share and the ratio.
local function least(k, units)
  local best
  for _, r in ipairs(B.race) do
    if not best or r[k][1] / r[k][2] > best[k][1] / best[k][2] then best = r end
  end
  local a, b = best[k][1], best[k][2]
  return { example = best.name, fframes = a / units[1], onimite = b / units[2], share = b / a, ratio = a / b }
end
B.cpu, B.memory = least("cpu", { 1, 1 }), least("rss", { 2 ^ 30, 2 ^ 20 })
-- Captions: "onimite is faster on 18 of 19 comparable examples.", "fframes
-- still wins hello_world and podcast." (or "fframes wins none of them.").
B.summary = string.format("onimite is faster on %d of %d comparable examples.", B.faster, B.compared)
local names = {}
for i, r in ipairs(B.losses) do names[i] = r.name end
B.losses_line = #names == 0 and "fframes wins none of them."
  or "fframes still wins " .. table.concat(names, ", "):gsub(", ([^,]*)$", " and %1") .. "."

-- What the other tools install before their first frame: name, version,
-- deps (subdependencies included), kind ("crates"), parts { name, MB } and
-- the total MB.
B.setup = {}
for _, s in ipairs(F.setup) do
  local t = { name = s.name, version = s.version, deps = s.deps, kind = s.kind, parts = {}, mb = 0 }
  for _, p in ipairs(s.parts) do
    t.parts[#t.parts + 1] = { p.name, p.bytes / 1e6 }
    t.mb = t.mb + p.bytes / 1e6
  end
  B.setup[#B.setup + 1] = t
end
-- onimite's Linux release: MB downloaded, and MB of files unpacked.
for _, i in ipairs(F.install) do
  if i.target == "linux-x86_64" then B.download_mb, B.disk_mb = i.download_bytes / 1e6, i.unpacked_bytes / 1e6 end
end

-- "3.6 GB", "682 MB": megabytes (10^6 bytes) as the films print sizes on
-- disk. Memory is printed in binary units, as the system reports it.
function B.size(mb) return mb >= 1000 and string.format("%.1f GB", mb / 1000) or string.format("%.0f MB", mb) end

-- Where and how it was measured, in a few words: "Ryzen 9 9900X3D + RX 9070
-- XT", "median of 5", "onimite v0.0.60 · fframes v1.3.0".
local m = F.measured
B.machine = m.machine.cpu:gsub("^AMD ", ""):gsub(" %d+%-Core Processor$", "") .. " + "
  .. m.machine.gpu:gsub("^AMD ", ""):gsub("^Radeon ", "")
B.runs = string.format("median of %d", m.kept)
B.versions = string.format("onimite %s · fframes %s", m.onimite.tag, m.fframes.tag or m.fframes.commit:sub(1, 7))

return B
