-- The clock and every cue, in beats from the start (120 BPM, 4 beats a bar,
-- 8 bars = 16 s). The picture (video.lua), the captions and the music
-- (track.lua) all read these numbers, so every cut lands on the grid.

local T = {}

T.FPS, T.BPM = 30, 120
T.clock = beat_clock(T.BPM)
T.BEAT = T.clock.spb
T.TOTAL = 32

-- Sections: start beat, scene name. Each runs to the next one's start.
T.SECTIONS = { { 0, "Hook" }, { 8, "Formats" }, { 16, "Features" }, { 24, "Outro" } }

-- Hook: Pip hops in, the two headline lines slam on beats 2 and 4, a riser
-- into the drop.
T.BO_IN, T.LINE1, T.LINE2, T.RISER = 0, 2, 4, 4
-- Formats: a frame a beat, then this video's own frame lights up.
T.FRAMES_GO, T.HERE = 9, 12
-- Features: four cuts, two beats each.
T.FEATURES_GO, T.FEATURE_LEN = 16, 2
-- Outro: the impact and the wordmark, the command, the formats.
T.MARK, T.PILL, T.CHIPS = 24, 26, 27

-- Where the kick plays (the picture pumps with it).
T.KICK = { { 8, 24 }, { 24, 30 } }
function T.kicking(b)
  for _, s in ipairs(T.KICK) do if b >= s[1] and b < s[2] then return true end end
  return false
end

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
