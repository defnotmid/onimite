-- Every cue, in beats from the start, read from the song (track.lua): its
-- sections are the promo's, its claps, blips and crashes the moments the
-- picture lands on. The picture (video.lua) and the captions read these
-- numbers, so every cut lands where the song hits.

local score = require("track")

local T = {}

T.FPS = 60

-- the beat of a position ("formats", "outro@0:3", "end"), or of each hit
local function B(pos) return score.beat(score.time(pos)) end
local function hits(part, range)
  local b = score.hits { part = part, range = range }
  for i, t in ipairs(b) do b[i] = score.beat(t) end
  return b
end

T.TOTAL = B("end")

-- Sections: start beat, scene name, song section. Each runs to the next
-- one's start (the outro through the song's tail).
T.SECTIONS = { { B("hook"), "Hook", "hook" }, { B("formats"), "Formats", "formats" },
  { B("features"), "Features", "features" }, { B("outro"), "Outro", "outro" } }

-- Hook: Pip hops in, the two headline lines slam on their claps; a riser
-- into the drop.
T.BO_IN = B("hook")
T.LINE1, T.LINE2 = table.unpack(hits("hits", "hook"))
-- Formats: a frame a blip, then this video's own frame lights up on the
-- double blip.
do
  local b = hits("blips", "formats")
  T.FRAMES = { b[1], b[2], b[3] }
  T.HERE = b[4]
end
-- Features: four cuts, a crash each.
T.FEATURE_CUTS = hits("crash", "features")
-- Outro: the impact and the wordmark, the command on its blip, the formats.
T.MARK = B("outro")
T.PILL = hits("blips", "outro")[1]
T.CHIPS = B("outro@0:3")

-- The voice-over the captions show, a cue per section, each word on its
-- beat. video.lua turns this into WebVTT with inline timestamps.
T.CAPTIONS = {
  { 0.5, "Meet", 1, "Pip.", 2, "One", 2.5, "script", 3, "makes", 3.25, "this", 3.5, "clip", stop = 6 },
  { 8, "in", 8.5, "every", 9, "shape", 9.5, "you", 10, "post:", 11, "tall,", 12, "square", 13, "or", 13.5, "wide.",
    stop = 15.5 },
  { 16, "Word", 16.5, "captions,", 18, "music", 18.5, "made", 19, "in", 19.25, "Lua,", 20, "cuts", 20.5, "on",
    20.75, "the", 21, "beat,", 22, "alpha", 22.5, "video.", stop = 23.75 },
  { 24.5, "Render", 25, "once,", 26, "ship", 26.5, "it", 27, "everywhere.", stop = 30.5 },
}

return T
