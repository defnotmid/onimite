-- The music: an odawg song, house at 120 BPM in C major (C Am F G, a chord a
-- bar), its sections named after the scenes. The house style plays the bed
-- (909 drums, an off-beat bass ducking under the kick, stabs, a pad, a pluck
-- arpeggio at full energy); the parts below are what the picture answers to,
-- placed in the sections and pitched from the data: a blip per month (higher
-- for a bigger harvest), a chime on the best month, a riser while the line
-- draws, a blip per crop, the count's ticks up the scale, crashes on the
-- scenes' downbeats. timeline.lua reads them back as the picture's cues.

-- The skill's library (skills/onimite-video/library: rows and styles to
-- copy into your media folder), from this example's media folder.
local LIB = "../../../skills/onimite-video/library/"
local INSTRUMENTS = { LIB .. "instruments/synths.json", LIB .. "instruments/classic.json", LIB .. "instruments/sfx.json" }

-- C major pentatonic, two octaves: a month's value picks its blip's note.
local PENTA = { "C5", "D5", "E5", "G5", "A5", "C6", "D6", "E6", "G6", "A6" }
local SCALE = { "C5", "D5", "E5", "F5", "G5", "A5", "B5", "C6", "D6", "E6", "F6", "G6" }
local MACHINE = { LIB .. "machines/909.json" }

-- A position in a section: beats and sixteenths from its start.
local function at(beat, sixteenth) return string.format("0:%d:%d", beat, sixteenth or 0) end

return function(months, crops)
  local hi = 0
  for _, v in ipairs(months) do hi = math.max(hi, v) end
  local blips, segments, ticks = {}, {}, {}
  for m, v in ipairs(months) do      -- a beat into "bars", a month a sixteenth
    blips[m] = { time = at(1, m - 1), note = PENTA[1 + math.floor(v / hi * (#PENTA - 1) + 0.5)], duration = "16n" }
  end
  for k = 1, crops do                -- a beat into "donut", a crop a beat
    segments[k] = { time = at(k), note = PENTA[2 + k], duration = "16n" }
  end
  for x = 1, 12 do                   -- a beat into "outro", twelve sixteenths up the scale
    ticks[x] = { time = at(1, x - 1), note = SCALE[x], duration = "16n", velocity = 0.45 }
  end
  local crashes = { { "outro", events = { { time = "1m", note = "crash" } } } }   -- the count lands
  for _, s in ipairs { "bars", "line", "donut", "outro" } do
    crashes[#crashes + 1] = { s, events = { { time = 0, note = "crash" } } }
  end

  return song { "score", instruments = INSTRUMENTS, key = "C major", bpm = 120, seed = 120, gain_db = -13,
    sections = {
      { "title", duration = "2m", style = LIB .. "styles/house.json", energy = 0.35, chords = "C Am" },
      { "bars", duration = "4m", energy = 0.72, chords = "F G C Am" },
      { "line", duration = "3m", energy = 0.8, chords = "F G C" },
      { "donut", duration = "3m", energy = 0.95, chords = "Am F G" },
      { "outro", duration = "2m", energy = 1, chords = "C Am" },
      { "tail", duration = "1m", style = LIB .. "styles/ambient.json", energy = 0.3, chords = "C", transition = "cut" },
    },
    parts = {
      -- the kick and the bass come in on the title's second bar; one last kick on the tail
      drums = { gain_db = 1, play = { { "title@1m..", steps = { kick = "x...x...x...x...", hat = "o.o.o.o.o.o.o.o." } },
                         { "tail", events = { { time = 0, note = "kick" } } } } },
      bass = { gain_db = 3, play = { { "title@1m..", degrees = ". . 1 . . . 1 8 . . 1 . . . 1 .", subdivision = "16n" } } },
      pad = { gain_db = -16 },
      arp = { gain_db = -10 },
      -- the crash, segments and ticks raised to where inspect's buried_part put them: 12 LU under the mix where each plays loudest
      crash = { instrument = MACHINE, gain_db = 2, play = crashes },
      impact = { instrument = "impact", gain_db = -12, play = { { "title", events = { { time = "2n", velocity = 0.6 } } } } },
      months = { instrument = "blip", gain_db = -6, play = { { "bars", events = blips } } },
      segments = { instrument = "blip", gain_db = -3, play = { { "donut", events = segments } } },
      ticks = { instrument = "blip", gain_db = -3, play = { { "outro", events = ticks } } },
      chimes = { instrument = "done", gain_db = -6, play = {
        { "bars", events = { { time = "2:2:0" } } },     -- the best month
        { "line", events = { { time = "1:3:0" } } },     -- the line lands on the total
        { "outro", events = { { time = "1m" } } },       -- the count lands
      } },
      -- the riser into the bars (v0.0.7 picked it from the energy; transitions are written out now)
      rise = { instrument = "riser", gain_db = -4,
        play = { { "title", events = { { time = 0, duration = "2m", note = "C4", velocity = 0.35 } } } } },
      riser = { instrument = "riser", gain_db = -10,     -- while the line draws
        play = { { "line", events = { { time = "4n", duration = "1:2:0" } } } } },
    },
  }
end
