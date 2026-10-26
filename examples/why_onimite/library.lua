-- The skill's library (skills/onimite-video/library: rows to copy into
-- your media folder), from this example's media folder: the track's 909,
-- synths and 808, the scenes' sound{} rows; and the crash the scenes land
-- on, a recorded cymbal (the virtuosity kit's, a sample set odawg fetches).
local LIB = "../../../skills/onimite-video/library/"
return {
  LIB = LIB,
  INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" },
  CRASH = sound { { "Sampler", set = "virtuosity/drums" }, note = "crash", duration = "2n" },
}
