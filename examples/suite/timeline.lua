-- Where things happen, in beats from the start, read from the song
-- (track.lua): its sections and the hits of its own parts. The picture
-- (world.lua, video.lua) animates from these numbers, so it moves when
-- the song does.

local score = require("track")

local T = {}

-- the beat of a position ("drop", "lockup@1m", "end"), or of each time
local function B(pos) return score.beat(score.time(pos)) end
local function beats(times)
  for i, t in ipairs(times) do times[i] = score.beat(t) end
  return times
end
local function hits(part, range) return beats(score.hits { part = part, range = range }) end

-- Ignition: the world fades up under the pad and the arp, the script's
-- lines drift in, the rocket rises on its blip; liftoff brings the kick
-- and a riser into the drop.
T.WORLD_IN = B("ignition")
T.ROCKET_IN = hits("blips", "ignition")[1]
-- The drop: the shader opens up, the rocket flies through; the alpha
-- clips arrive in their portals on their blips, one a bar.
T.DROP = B("drop")
T.PORTALS = hits("blips", "drop")
-- A second phase: the world turns into a kaleidoscope of the same group,
-- until the stutter before the break.
T.KALEIDO = B("kaleido")
T.GLITCH = hits("glitch", "kaleido")[1]
-- The break: kick out, the suite's structure draws itself, unwarped, a box
-- a blip (ovg, oksl, oicut, SDL3 under onimite; o3d's box lands with the
-- SDL3 row, then odawg's and ottis's), while ottis says the line.
T.BREAK = B("break")
T.BOXES = hits("blips", "break")
T.O3D_BOX = T.BOXES[4]
-- The lockup: a name an eighth, the seventh with the line on its crash,
-- then the last hit and the tail.
T.LOCKUP = B("lockup")
T.NAMES = hits("blips", "lockup")
T.LINE = hits("crash", "lockup")[1]
T.END = B("tail")
T.TOTAL = B("end")

return T
