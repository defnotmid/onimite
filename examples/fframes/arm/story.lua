-- The performance (fframes' story.rs): keys with anticipation, overshoot and idle motion,
-- the letters' timelines, the throw of the "a" (physics3d{}), the sounds and the console
-- lines. Built once when the script loads.

local A = require("arm")
local S = {}

local TAU = 2 * math.pi
local add, sub, sc = vec3_add, vec3_sub, vec3_scale
local compose, inverse = mat4_multiply, mat4_invert
local function at(p) return mat4_compose(p) end
local function apply(m, v) return vec3_apply_mat4(v, m) end

S.HELLO, S.GUILTY, S.FINAL = { 3.2, 1.25, 4.9 }, { 0.55, 1.32, 3.25 }, { 0.0, 1.25, 7.2 }
local OPEN, TOOL_DOWN = A.OPEN, A.TOOL_DOWN

-- the easings into a key: { name, overshoot }
local EASE = {
  smooth = function(x) return x * x * x * (x * (x * 6 - 15) + 10) end,
  out = function(x) return 1 - (1 - x) ^ 3 end,
  ["in"] = function(x) return x * x * x end,
  out_back = function(x, s) return 1 + (s + 1) * (x - 1) ^ 3 + s * (x - 1) ^ 2 end,
  in_back = function(x, s) return (s + 1) * x * x * x - s * x * x end,
}
local SMOOTH, OUT, IN = { "smooth" }, { "out" }, { "in" }
local function out_back(s) return { "out_back", s } end

local keys = {}
-- The arm at t: its joints (with the idle sway) and half its finger gap.
function S.sample(t)
  local k = 0
  while k < #keys and keys[k + 1].t <= t do k = k + 1 end
  local a, b = keys[math.max(k, 1)], keys[math.min(k + 1, #keys)]
  local q, gap, alive = a.q, a.gap, a.alive
  if k > 0 and k < #keys then
    local s = (t - a.t) / math.max(b.t - a.t, 1e-6)
    local x = EASE[b.ease[1]](clamp01(s), b.ease[2])
    q, gap, alive = {}, a.gap + (b.gap - a.gap) * x, a.alive + (b.alive - a.alive) * clamp01(s)
    for i = 1, 6 do q[i] = a.q[i] + (b.q[i] - a.q[i]) * x end
  end
  local s = math.sin
  local idle = { 0.035 * s(t * 1.3), 0.03 * s(t * 1.7 + 1), 0.04 * s(t * 2.1 + 2), 0.05 * s(t * 0.9 + 3),
    0.07 * s(t * 1.1 + 0.5), 0.04 * s(t * 0.7 + 1.5) }
  local out = {}
  for i = 1, 6 do out[i] = q[i] + idle[i] * alive end
  return out, gap
end

-- ------------------------------------------------------------------ the letters

-- Inter ExtraBold 0.68 high and 10 cm deep, spelled with 3.5 cm tracking; each waits in the
-- rack in this order, left to right.
function S.letters(word, word_z, rack_z)
  local chars = text_chars { word, font = "Inter 18pt", weight = 800, size = 0.68 }
  local width = chars[#chars].x + chars[#chars].w + 0.035 * (#chars - 1)
  local rack_order = { 4, 1, 6, 0, 3, 5, 2 }
  local letters = {}
  for i, ch in ipairs(chars) do
    local shape = outline { ch.text, font = "Inter 18pt", weight = 800, size = 0.68 }
    local x, y, w, h = outline_bounds(shape)
    -- outline units run down: the glyph spans -(y + h) .. -y
    local function band(lo, hi)
      return outline { d = string.format("M%f %f H%f V%f H%f Z", x - 1, -hi, x + w + 1, -lo, x - 1) }
    end
    -- the grip point: the middle of its top 3 cm; its rightmost stem a third of the way up
    local tx, _, tw = outline_bounds(outline_intersect(shape, band(-y - 0.03, -y + 0.01)))
    local stem_y, stem = -(y + h) + 0.32 * h, nil
    for _, piece in ipairs(outline_divide(shape, band(stem_y - 0.0005, stem_y + 0.0005))) do
      local px, _, pw = outline_bounds(piece.outline)
      if #piece.inside == 2 and (not stem or px + pw > stem[1] + stem[2]) then stem = { px, pw } end
    end
    local slot = 0
    for k, r in ipairs(rack_order) do if r == i - 1 then slot = k - 1 end end
    letters[i] = { shape = shape, center = { x + w / 2, -y - h / 2, 0 }, size = { w, h, 0.1 },
      top = { tx + tw / 2, -y - 0.035, 0 }, stem = { { stem[1] + stem[2] / 2, stem_y, 0 }, stem[2] / 2 },
      rack = at({ -1.56 + slot * 0.52 - (x + w / 2), 0.02, rack_z }),
      slot = at({ ch.x + (i - 1) * 0.035 - width / 2, 0, word_z }) }
    letters[i].phases = { { t = 0, still = letters[i].rack } }
  end
  return letters
end

-- ------------------------------------------------------------------ the performance

function S.new(letters, word_z, rack_z)
  local st = { sounds = {}, log = {}, blinks = {}, beats = {}, letters = letters, keys = keys }
  local beats, tnow = st.beats, 0
  local function sound(t, name, gain) st.sounds[#st.sounds + 1] = { t = t, name = name, gain = gain } end
  local function say(t, text, alert) st.log[#st.log + 1] = { t = t, text = text, alert = alert } end
  local function blink(t) st.blinks[#st.blinks + 1] = t end
  local function key(dt, q, gap, ease, alive)
    tnow = tnow + dt
    keys[#keys + 1] = { t = tnow, q = q, gap = gap, ease = ease, alive = alive }
  end
  local function last() return keys[#keys] end
  local function pose(dt, p, rot, gap, ease, alive) key(dt, A.solve(p, rot, last().q), gap, ease, alive) end
  local function look(dt, from, to, roll, ease, alive)
    pose(dt, from, A.looking(sub(to, from), roll), last().gap, ease, alive)
  end
  local function hold(dt, alive) key(dt, last().q, last().gap, SMOOTH, alive) end
  local function grip(dt, gap) key(dt, last().q, gap, OUT, 0) end
  local function nudge(dt, d, ease, alive)
    local q = {}
    for i = 1, 6 do q[i] = last().q[i] + d[i] end
    key(dt, q, last().gap, ease, alive)
  end
  local function lift(p, h) return add(p, { 0, h, 0 }) end
  -- the letter as it hangs from the grip point at t
  local function take(l, t)
    local rel = compose(inverse(A.tip(S.sample(t))), l.rack)
    l.phases[#l.phases + 1] = { t = t, carried = rel }
    return rel
  end

  -- asleep in the dark lab; the eye boots
  keys[1] = { t = 0, q = A.solve({ 0.05, 0.24, 0.95 }, A.looking({ 0.05, -1, 0.45 }, 0.25), { 0, 0.4, 1, 0, 0.8, 0 }),
    gap = 0.03, ease = SMOOTH, alive = 0.15 }
  beats.wake = 0.8
  sound(0.75, "boot"); say(0.8, "BOOT  OD-ARM 7.2 ...... OK")
  hold(2.0, 0.15)
  -- waking: a tired lift with a sag, a stretch (the lights flicker on), then curiosity
  look(0.9, { 0.1, 0.62, 0.95 }, { 0.2, 0, 2.2 }, 0.15, { "in_back", 0.4 }, 0.3)
  nudge(0.35, { 0, 0.08, 0.1, 0, 0.25, 0 }, SMOOTH, 0.2)
  blink(tnow + 0.1); sound(tnow + 0.1, "blink")
  look(0.75, { 0, 2.15, 0.55 }, { 0, 3.5, 1.4 }, 0, out_back(1.6), 0)
  beats.lights = tnow - 0.2; sound(beats.lights, "lights")
  grip(0.2, OPEN)
  look(0.55, { 0.25, 1.35, 1.05 }, S.HELLO, 0.35, out_back(1.2), 0.5)
  sound(tnow - 0.2, "curious"); say(tnow - 0.2, "VISION ONLINE  FACE DETECTED")
  look(0.25, { 0.25, 1.35, 1.05 }, S.HELLO, -0.25, SMOOTH, 0.4)
  blink(tnow); sound(tnow, "blink")
  hold(0.3, 0.6)
  -- the rack, quickly the camera, then happily the rack
  local rack_center = { 0, 0.3, rack_z }
  look(0.45, { -0.2, 1.4, -0.35 }, rack_center, 0, SMOOTH, 0.3)
  look(0.2, { 0.2, 1.4, 0.7 }, S.HELLO, 0.2, OUT, 0.2)
  look(0.3, { -0.15, 1.45, -0.4 }, rack_center, -0.1, out_back(1.3), 0.3)
  sound(tnow, "happy"); say(tnow, 'TASK  SPELL "fframes"')
  hold(0.25, 0.5)
  beats.work = tnow

  -- the work: each letter carried 68 cm over the rack and the word, the tool pointing down
  local CARRY = 0.68
  local function pick_place(i, pace, flourish, line)
    local l = letters[i + 1]
    local grab, place = apply(l.rack, l.top), apply(l.slot, l.top)
    pose(0.62 * pace, lift(grab, CARRY), TOOL_DOWN, OPEN, SMOOTH, 0)
    pose(0.24 * pace, grab, TOOL_DOWN, OPEN, SMOOTH, 0)
    grip(0.12 * pace, 0.057)
    sound(tnow - 0.04 * pace - 0.05, "grip")
    take(l, tnow - 0.04 * pace)
    pose(0.24 * pace, lift(grab, CARRY), TOOL_DOWN, 0.057, out_back(0.6), 0)
    sound(tnow, "whoosh")
    pose(0.62 * pace, lift(place, CARRY), TOOL_DOWN, 0.057, flourish and out_back(1) or SMOOTH, 0)
    pose(0.24 * pace, place, TOOL_DOWN, 0.057, IN, 0)
    l.phases[#l.phases + 1] = { t = tnow, still = l.slot, placed = true }
    sound(tnow, "place"); say(tnow, line)
    l.placed = tnow
    grip(0.1 * pace, OPEN)
    pose(0.22 * pace, lift(place, 0.35), TOOL_DOWN, OPEN, OUT, 0.2)
  end
  pick_place(0, 1.05, false, "PLACE  f ............. OK")
  pick_place(1, 0.8, false, "PLACE  f ............. OK")
  -- too confident: a wiggle after the r
  pick_place(2, 0.68, true, "PLACE  r ............. OK")
  nudge(0.12, { 0, 0, 0, 0, 0, 0.5 }, OUT, 0)
  nudge(0.12, { 0, 0, 0, 0, 0, -1 }, SMOOTH, 0)
  nudge(0.14, { 0, 0, 0, 0, 0, 0.5 }, out_back(1), 0)
  sound(tnow, "happy")

  -- the swing: the "a" up, back, then round in a spin; the gripper opens too early
  local la = letters[4]
  st.dropped = la
  local grab = apply(la.rack, la.top)
  pose(0.5, lift(grab, CARRY), TOOL_DOWN, OPEN, SMOOTH, 0)
  pose(0.2, grab, TOOL_DOWN, OPEN, SMOOTH, 0)
  grip(0.1, 0.057)
  sound(tnow - 0.08, "grip")
  local rel = take(la, tnow - 0.03)
  say(tnow, "PLACE  a  WITH STYLE")
  pose(0.3, add(grab, { 0, 1.05, 0.25 }), TOOL_DOWN, 0.057, out_back(0.8), 0)
  nudge(0.25, { 0.12, -0.1, -0.1, 0, 0, -0.6 }, SMOOTH, 0)
  local swing_from = tnow
  local q = A.solve(add(lift(apply(la.slot, la.top), CARRY), { 0.25, 0.25, 0 }), TOOL_DOWN, last().q)
  q[6] = q[6] + TAU * 1.5
  key(0.95, q, 0.057, { "in_back", 0.25 }, 0)
  sound(swing_from + 0.15, "whoosh")
  beats.drop = swing_from + 0.62
  -- the throw: the letter's velocity and spin as it leaves the gripper, aimed to land in view
  local function held(t) return compose(A.tip(S.sample(t)), rel) end
  local dt = 1 / 240
  local m0, ma, mb = held(beats.drop), held(beats.drop - dt), held(beats.drop + dt)
  local p0 = apply(m0, la.center)
  local vy = clamp((apply(mb, la.center)[2] - apply(ma, la.center)[2]) / (2 * dt), -0.5, 1.5)
  local flight = (vy + math.sqrt(vy * vy + 2 * 9.81 * p0[2])) / 9.81
  local reach = sc(sub({ 1.3, 0, 0.4 }, p0), 0.85 / flight)
  local _, turned = mat4_decompose(compose(mb, inverse(ma)))
  local spin = quat_from_euler(turned)
  local angle = 2 * math.acos(clamp(spin[4], -1, 1))
  local axis = vec3_normalize({ spin[1], spin[2], spin[3] })
  st.throw = shared("arm-throw", function()
    return physics3d { duration = 4, rate = 480, bodies = {
      { static = true, box = { 30, 0.2, 30 }, position = { 0, -0.1, 0 } },
      { name = "a", box = la.size, position = p0, rotation = select(2, mat4_decompose(m0)),
        velocity = { reach[1], vy, reach[3] },
        spin = sc(axis, angle / (2 * dt) * 0.6), bounce = 0.32 },
    } }
  end)
  local function thrown(t)
    local pos, e = physics3d_at(st.throw, "a", t - beats.drop)
    return compose(mat4_compose(pos, e), at(sc(la.center, -1)))
  end
  st.thrown = thrown
  local lying = thrown(beats.drop + 4)
  la.phases[#la.phases + 1] = { t = beats.drop, falling = true }
  la.phases[#la.phases + 1] = { t = beats.drop + 4, still = lying }
  -- each bounce: the contacts of its corners within 50 ms are one hit, as fast as the fastest
  st.impacts = {}
  for _, c in ipairs(st.throw.contacts) do
    local last_hit = st.impacts[#st.impacts]
    if last_hit and beats.drop + c.t - last_hit.t < 0.05 then
      if c.speed > last_hit.speed then last_hit.speed, last_hit.at = c.speed, c.position end
    else
      st.impacts[#st.impacts + 1] = { t = beats.drop + c.t, speed = c.speed, at = c.position }
    end
  end
  for _, h in ipairs(st.impacts) do sound(h.t, "clatter", -14 + 4 * math.min(h.speed, 4)) end
  sound(beats.drop, "scratch"); sound(beats.drop - 0.05, "grip")
  say(beats.drop + 0.05, "ERR 0x7A  GRIP LOST", true)

  -- after the drop: a slow turn to the letter, a look into the camera, the sigh
  grip(0.15, OPEN)
  hold(0.55, 0)
  local letter_at = apply(lying, la.center)
  local from = mat4_decompose(A.tip(last().q))
  look(0.8, add(from, { 0, -0.1, 0 }), letter_at, 0.2, SMOOTH, 0.1)
  sound(tnow - 0.1, "uhoh"); say(tnow, "STATUS  NOBODY SAW THAT")
  hold(0.5, 0.2)
  local guilty = { 0.3, 1.3, 1.25 }
  look(0.7, guilty, S.GUILTY, -0.25, SMOOTH, 0)
  blink(tnow + 0.5); sound(tnow + 0.5, "blink")
  hold(1.0, 0.3)
  look(0.16, guilty, letter_at, 0.1, OUT, 0)
  hold(0.18, 0)
  look(0.16, guilty, S.GUILTY, -0.2, OUT, 0)
  hold(0.35, 0.2)
  blink(tnow - 0.1); say(tnow, "SOMEBODY SAW THAT", true)
  nudge(0.75, { 0, 0.18, 0.28, 0, 0.45, 0 }, SMOOTH, 0)
  sound(tnow - 0.6, "sigh")
  hold(0.35, 0.2)
  beats.recover = tnow

  -- the careful recovery: grab the stem, stand the letter up in the air, lower it into place
  say(tnow, "RETRY  a  (CAREFULLY)")
  local stem = apply(lying, la.stem[1])
  -- the tool down through the letter's face, whichever face it lies on
  local _, _, face = mat4_extract_basis(lying)
  local grab_rot = compose(lying, A.frame({ 1, 0, 0 }, { 0, 0, face[2] > 0 and -1 or 1 }))
  look(0.75, add(stem, { 0, 0.55, 0.25 }), stem, 0.3, SMOOTH, 0.1)
  hold(0.3, 0.2)
  pose(0.6, lift(stem, 0.3), grab_rot, OPEN, SMOOTH, 0)
  pose(0.45, stem, grab_rot, OPEN, SMOOTH, 0)
  local stem_gap = la.stem[2] + 0.007
  grip(0.2, stem_gap)
  sound(tnow - 0.1, "grip")
  local rel2 = compose(inverse(A.tip(S.sample(tnow - 0.05))), lying)
  la.phases[#la.phases + 1] = { t = tnow - 0.05, carried = rel2 }
  pose(0.55, lift(stem, 0.4), grab_rot, stem_gap, SMOOTH, 0)
  local slot_tip = compose(la.slot, inverse(rel2))
  local slot_at = mat4_decompose(slot_tip)
  pose(1.0, lift(slot_at, 0.35), slot_tip, stem_gap, SMOOTH, 0)
  pose(0.5, slot_at, slot_tip, stem_gap, SMOOTH, 0)
  la.phases[#la.phases + 1] = { t = tnow, still = la.slot, placed = true }
  sound(tnow, "place"); say(tnow, "PLACE  a ............. OK")
  grip(0.12, OPEN)
  local _, _, back = mat4_extract_basis(slot_tip)
  pose(0.35, add(add(slot_at, sc(back, -0.2)), { 0, 0.05, 0 }), slot_tip, OPEN, OUT, 0)
  -- two pats on the letter
  local top = apply(la.slot, la.top)
  pose(0.45, lift(top, 0.16), TOOL_DOWN, 0.03, SMOOTH, 0)
  for _ = 1, 2 do
    pose(0.1, lift(top, 0.05), TOOL_DOWN, 0.03, IN, 0); sound(tnow, "pat")
    pose(0.14, lift(top, 0.16), TOOL_DOWN, 0.03, OUT, 0)
  end
  nudge(0.25, { 0, -0.05, -0.05, 0, -0.3, 0 }, out_back(1.5), 0.3)
  sound(tnow - 0.1, "happy")
  beats.finish = tnow

  -- confident again: m, e, s; then admire, bow, ta-da
  pick_place(4, 0.62, false, "PLACE  m ............. OK")
  pick_place(5, 0.58, false, "PLACE  e ............. OK")
  pick_place(6, 0.56, false, "PLACE  s ............. OK")
  say(tnow + 0.1, "TASK COMPLETE  1 INCIDENT")
  look(0.7, { 0, 1.55, 0.55 }, { 0, 0.25, word_z }, 0, SMOOTH, 0.3)
  hold(0.5, 0.5)
  look(0.5, { 0, 1.5, 0.75 }, S.FINAL, 0.25, out_back(1.2), 0.3)
  sound(tnow - 0.1, "proud")
  hold(0.35, 0.4)
  nudge(0.45, { 0, 0.22, 0.3, 0, 0.65, 0 }, SMOOTH, 0)
  hold(0.25, 0)
  nudge(0.4, { 0, -0.24, -0.32, 0, -0.7, 0 }, out_back(1.3), 0.2)
  beats.tada = tnow
  sound(tnow, "tada"); say(tnow, "HUMILITY  NOT FOUND")
  for _ = 1, 2 do grip(0.09, 0.02); grip(0.09, OPEN) end
  blink(tnow + 0.2)
  hold(1.7, 0.6)
  beats["end"] = tnow
  return st
end

-- Where a letter is at t: its phase, and its world transform.
function S.phase(l, t)
  local p = l.phases[1]
  for _, x in ipairs(l.phases) do if x.t <= t then p = x end end
  return p
end
function S.world(st, l, t)
  local p = S.phase(l, t)
  if p.still then return p.still end
  if p.carried then return compose(A.tip(S.sample(t)), p.carried) end
  return st.thrown(t)
end

return S
