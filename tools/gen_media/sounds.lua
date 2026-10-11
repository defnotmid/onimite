-- The example sounds, synthesized: `--set sound=NAME` picks one and
-- `onimite audio render` writes it as a WAV (gen.sh then converts it to the
-- format the example demonstrates).
--
--   music   10 s, 120 BPM in F: pad, plucked arp, sub, kick and hats
--           (audio_demo and media_demo's music.mp3)
--   pop     0.12 s pitch-drop pop (audio_demo's pop.wav)
--   whoosh  0.6 s swept noise, panned across (audio_demo's whoosh.ogg)
--
--     onimite audio render tools/gen_media/sounds.lua --set sound=music -o music.wav

local S = require("synth")

local BEAT = 0.5 -- 120 BPM

-- Fmaj9 Am7 Dm9 Bbmaj7, a chord a bar, and the bass roots.
local CHORDS = { { 53, 57, 60, 64, 67 }, { 57, 60, 64, 67 }, { 50, 57, 60, 64, 65 }, { 46, 53, 57, 62, 65 } }
local ROOTS = { 41, 45, 38, 46 }

local function music()
  local b = S.buffer(10, 120)
  -- the bass and pad dip under every kick (beats 4..17)
  local function kicking(beat) return beat >= 4 and beat < 18 end
  b.duck = function(t)
    local k = math.floor(t / BEAT)
    if not kicking(k) then return 1 end
    return 1 - 0.7 * math.exp(-(t - k * BEAT) / 0.08)
  end
  for bar = 0, 4 do
    local i = bar % 4 + 1
    local notes, t0 = CHORDS[i], bar * 4 * BEAT
    -- the pad: last bar rings out under the fade
    S.chord(b, t0, 4 * BEAT + 0.05, notes, bar == 0 and 0.07 or 0.045, 700 + bar * 200, 0.3, bar == 4 and 0.6 or 0)
    for q = 0, 3 do
      local beat = bar * 4 + q
      if kicking(beat) then S.kick(b, beat * BEAT, 0.8) end
      if beat >= 4 and beat < 18 then S.sub(b, (beat + 0.5) * BEAT, BEAT * 0.45, ROOTS[i] + 12, 0.3) end
    end
    for s = 0, 15 do -- sixteenths
      local t = t0 + s * BEAT / 4
      if bar >= 1 and bar <= 3 and s % 2 == 1 then S.hat(b, t, 0.04, 90, s % 4 == 3 and 0.14 or 0.08) end
      -- the arp: an eighth apart, bouncing between the sides, with one echo
      if s % 2 == 0 and bar < 4 then
        local note = notes[(s // 2) % #notes + 1] + 12
        S.pluck(b, t, note, 0.07, s % 4 == 0 and -0.3 or 0.3)
        S.pluck(b, t + 0.75 * BEAT, note, 0.025, s % 4 == 0 and 0.3 or -0.3)
      end
    end
  end
  S.bell(b, 16 * BEAT, 77, 0.12, 0, 1.5)
  return S.wav(b)
end

local function pop()
  local b = S.buffer(0.12, 2)
  S.pop(b, 0, 1, 0)
  return S.wav(b)
end

local function whoosh()
  local b = S.buffer(0.6, 3)
  S.whoosh(b, 0, 0.6, 1)
  return S.wav(b)
end

local SOUNDS = { music = { music, 10 }, pop = { pop, 0.12 }, whoosh = { whoosh, 0.6 } }
local pick = SOUNDS[props.sound or "music"]
assert(pick, "--set sound=music|pop|whoosh")

audio_add("sound.wav", shared("sound", pick[1]))

video { width = 64, height = 64, fps = 100, duration = pick[2], limiter = false,
  audio = { { "sound.wav", start = 0 } } }
