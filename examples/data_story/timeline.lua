-- Every cue the picture uses, read from the score (track.lua) in video
-- seconds: where its sections start, and the notes it really plays there.
-- The blips, chimes and the riser are the moments; the cues let `inspect`
-- and `frame video.lua month[3]` find them.

return function(score)
  local T = { FPS = 60 }
  T.BEAT = score.seconds("4n")   -- a beat: each transition's length
  T.SCENES = { { "title", "Title" }, { "bars", "Bars" }, { "line", "Line" }, { "donut", "Donut" }, { "outro", "Outro" } }

  -- Title: the emoji pops, the name slams on the impact, the subtitle follows.
  T.EMOJI, T.SUB = score.time("title@4n"), score.time("title@2n.")
  T.NAME = cue("slam", score.hits { part = "impact" }[1])
  -- Bars: twelve months rise on their blips, the best month lights up on the chime.
  T.MONTHS = cue("month", score.hits { part = "months" })
  T.PEAK = cue("peak", score.hits { part = "chimes", range = "bars" }[1])
  -- Line: the running total draws while the riser swells, and pops on the chime.
  local riser = score.events { part = "riser" }[1]
  T.LINE_GO, T.LINE_END = riser.time, riser.time + riser.duration
  -- Donut: a segment and its legend row on each blip.
  T.SEGMENTS = cue("segment", score.hits { part = "segments" })
  -- Outro: the total counts up over the ticks and lands on the chime.
  T.COUNT_GO = score.hits { part = "ticks" }[1]
  T.COUNT_END = cue("total", score.hits { part = "chimes", range = "outro" }[1])
  return T
end
