-- Where things happen, in beats from the start (120 BPM, a beat is 30
-- frames). The picture (world.lua, video.lua) and the music (track.lua)
-- read these numbers, so they share one list.

local T = {}

T.TOTAL = 72 -- 18 bars, 36 s

-- Ignition: the world fades up under hats and a pad, the script's lines
-- drift in, the rocket rises; a riser into the drop.
T.WORLD_IN = 0
T.ROCKET_IN = 4
T.RISER = 12
-- The drop: the shader opens up, the rocket flies through.
T.DROP = 16
-- The alpha clips arrive in their portals, one a bar.
T.PORTALS = { 20, 24 }
-- A second phase: the world turns into a kaleidoscope of the same group.
T.KALEIDO = 32
T.GLITCH = 47
-- The break: kick out, the suite's structure draws itself, unwarped.
T.BREAK = 48
T.BOXES = { 49, 50, 51, 52 } -- ovg, oksl, odecs, SDL3 under onimite (48)
T.RISER2 = 52
-- The lockup: the four names, the line, then the last hit and a tail.
T.LOCKUP = 56
T.NAMES = { 56, 57, 58, 59 }
T.LINE = 60
T.END = 68

return T
