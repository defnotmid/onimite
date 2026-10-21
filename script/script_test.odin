package onimite_script

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import "deps:o3d"
import om "../onimite"
import "../speech"

// text_width, text_fit and text_lines work at load, with the media the
// script was loaded with (no render in progress).
@(test)
test_measure_at_load :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local w = text_width { "Hello", size = 20 }
local fitted = text_fit { "A long title that does not fit", size = 20, max_width = 100 }
local lines = text_lines { "one two three four five six", size = 20, max_width = 80 }
assert(w > 30 and w < 80, w)
assert(#fitted < 30 and text_width { fitted, size = 20 } <= 100, fitted)
assert(#lines >= 3, #lines)
video { width = math.floor(w), height = 90, fps = 30, duration = 1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)

	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	ok := load(&s, path, nil, &media)
	testing.expectf(t, ok == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	w, _ := om.text_width(&media, {size = 20}, "Hello")
	testing.expect_value(t, s.video.width, int(w))

	// Without the media, measuring at load is an error naming the call.
	s2: Script
	defer unload(&s2)
	testing.expect(t, load(&s2, path, nil) != nil)
}

// `shared` builds its value in the first state loaded with a `Shared`; the
// others get a copy (identity, cycles, integer/float subtypes and path
// handles kept) without running the build again.
@(test)
test_shared_values :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local built = false
local v = shared("data", function()
  built = true
  local inner = { 1, 2, 3 }
  local t = { a = inner, b = inner, n = 7, x = 0.1, s = "text", yes = true, no = false,
    d = path_data("M0 0 L10 0 L10 10 Z"), [0] = "zero" }
  t.self = t
  return t
end)
assert(v.a == v.b and v.self == v and #v.a == 3 and v.a[3] == 3)
assert(math.type(v.n) == "integer" and v.x == 0.1 and v.s == "text" and v.yes and v.no == false)
assert(v[0] == "zero" and v.d == path_data("M0 0 L10 0 L10 10 Z"))
assert(not pcall(shared, "bad", function() return { print } end))
video { width = built and 100 or 200, height = 90, fps = 30, duration = 1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)

	sh: Shared
	defer shared_destroy(&sh)
	first, second: Script
	defer unload(&first)
	defer unload(&second)
	testing.expectf(t, load(&first, path, nil, nil, &sh) == nil, "load failed: %s", error_message(first.failure, context.temp_allocator))
	testing.expectf(t, load(&second, path, nil, nil, &sh) == nil, "load failed: %s", error_message(second.failure, context.temp_allocator))
	testing.expect_value(t, first.video.width, 100)
	testing.expect_value(t, second.video.width, 200)
	testing.expect_value(t, len(sh.paths), 1)
	for _, a in sh.paths {
		testing.expect_value(t, len(a.verbs), 4)
	}
}

// std.lua: sequence, series, loop, freeze, stagger, beat_clock and the
// transitions' endpoints, checked at load (group and rect stubbed to
// record what a transition draws).
@(test)
test_std_lib :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local function near(a, b) return math.abs(a - b) < 1e-9 end
-- math helpers, noise and colour mixing
assert(near(lerp(0, 10, 0.25), 2.5) and clamp(5, 0, 3) == 3 and near(progress(5, 0, 10), 0.5))
assert(near(remap(5, 0, 10, 100, 200), 150) and near(smoothstep(0, 1, 0.5), 0.5))
assert(near(fract(-1.25), 0.75) and round(-2.5) == -3 and sign(-3) == -1)
local n1, n2 = noise(0.3, 0.7), noise(0.3, 0.7, nil, 7)
assert(n1 >= -1 and n1 <= 1 and n1 ~= n2 and noise(0.3, 0.7) == n1)
local half = mix_color("#ff0000", "#0000ff", 0.5, "srgb")
assert(near(half.r, 0.5) and near(half.b, 0.5) and near(half.a, 1))
local same = mix_color("#336699", "#336699", 0.3)
assert(math.abs(same.r - 0.2) < 1e-3 and math.abs(same.b - 0.6) < 1e-3)
local function frame(i) return { index = i, global_index = i, fps = 30, seconds = i / 30, global_seconds = i / 30 } end

-- sequence: local clock, progress, open end, nesting
local seen
assert(sequence(frame(29), 1, 2, function() return 1 end) == nil)
sequence(frame(30), 1, 2, function(g) seen = g end)
assert(seen.index == 0 and near(seen.seconds, 0) and near(seen.progress, 0) and seen.global_index == 30)
sequence(frame(45), 1, 2, function(g) seen = g end)
assert(seen.index == 15 and near(seen.seconds, 0.5) and near(seen.progress, 0.25))
assert(sequence(frame(90), 1, 2, function() return 1 end) == nil)
assert(sequence(frame(9000), 1, nil, function(g) return g.index end) == 8970)
local inner = sequence(frame(60), 1, 2, function(g)
  return sequence(g, 0.5, 1, function(h) return h end)
end)
assert(inner.index == 15 and near(inner.seconds, 0.5) and near(inner.progress, 0.5) and inner.global_index == 60)
assert(sequence(frame(90), 1, 2, function(g) return sequence(g, 0.5, 1, function() return 1 end) end) == nil)

-- series: back to back, open last item, nothing past a closed end
local function which(i)
  return series(frame(i), { { 0.1, function(g) return "a" .. g.index end },
                            { 0.2, function(g) return "b" .. g.index end },
                            { 0.3, function(g) return "c" .. g.index end } })
end
assert(which(0) == "a0" and which(2) == "a2" and which(3) == "b0" and which(8) == "b5" and which(9) == "c0")
assert(which(17) == "c8" and which(18) == nil)
assert(series(frame(300), { { 1, print }, { nil, function(g) return g.index end } }) == 270)

-- loop
local l = loop(frame(75), 1, function(g) return g end)
assert(l.index == 15 and near(l.seconds, 0.5) and near(l.progress, 0.5) and l.iteration == 2)
assert(loop(frame(60), 1, function(g) return g.index end) == 0)
assert(loop(frame(59), 1, function(g) return g.index end) == 29)

-- freeze
local fr = freeze(frame(200), 1.5, function(g) return g end)
assert(fr.index == 45 and near(fr.seconds, 1.5) and fr.global_index == 200)
assert(sequence(frame(100), 2, 3, function(g) return freeze(g, 0.25, function(h) return h.index end) end) == 7)

-- stagger
assert(stagger(1, 0.1) == 0 and near(stagger(4, 0.1), 0.3))
assert(near(stagger(1, 0.1, { n = 5, from = "end" }), 0.4) and stagger(5, 0.1, { n = 5, from = "end" }) == 0)
assert(stagger(3, 0.1, { n = 5, from = "center" }) == 0 and near(stagger(1, 0.1, { n = 5, from = "center" }), 0.2))
assert(near(stagger(2, 0.1, { n = 4, from = "center" }), 0.05))
assert(near(stagger(5, nil, { n = 5, amount = 2 }), 2) and near(stagger(3, nil, { n = 5, amount = 2 }), 1))
assert(near(stagger(3, 0.1, { n = 5, easing = ease_in }), 0.4 * 0.125))
assert(near(stagger(4, 0.1, { n = 7, from = 2 }), 0.2))
assert(not pcall(stagger, 1, 0.1, { from = "end" }))

-- beat_clock and pulse
local c = beat_clock(120, 0.5)
assert(near(c.beat(frame(60)), 3) and near(c.bar(2.5), 1) and near(c.time(4), 2.5) and near(c.seconds(4), 2))
assert(c.frame(1, 30) == 30 and near(c.pulse(2.5, 8), 1) and c.pulse(0, 8) == 0)
assert(near(pulse(3, 4), 1) and near(pulse(3.25, 4), math.exp(-1)) and pulse(-0.5, 4) == 0)

-- transitions: p <= 0 draws only a, p >= 1 only b, between both
local drawn, groups
local function A() drawn[#drawn + 1] = "a" end
local function B() drawn[#drawn + 1] = "b" end
group = function(props, fn) groups[#groups + 1] = props fn() end
rect = function() end
for _, kind in ipairs { "fade", "slide", "wipe", "clock_wipe", "zoom", "glitch" } do
  for _, opts in ipairs { {}, { from = "top", softness = 40 }, { from = "right", x = 10, y = 20, w = 300, h = 200 } } do
    drawn, groups = {}, {}
    transition(kind, 0, A, B, opts)
    assert(#drawn == 1 and drawn[1] == "a" and #groups == 0, kind)
    drawn = {}
    transition(kind, 1, A, B, opts)
    assert(#drawn == 1 and drawn[1] == "b", kind)
    drawn = {}
    transition(kind, -1, A, nil, opts)
    transition(kind, 2, nil, B, opts)
    assert(#drawn == 2 and drawn[1] == "a" and drawn[2] == "b", kind)
    drawn = {}
    transition(kind, 0.5, A, B, opts)
    local a, b = 0, 0
    for _, d in ipairs(drawn) do if d == "a" then a = a + 1 else b = b + 1 end end
    assert(a > 0 and b > 0, kind)
  end
end
drawn, groups = {}, {}
transition("fade", 0.25, A, B)
assert(groups[1].opacity == 0.75 and groups[2].opacity == 0.25)
assert(not pcall(transition, "spin", 0.5, A, B))
assert(not pcall(transition, "slide", 0.5, A, B, { from = "up" }))

video { width = 64, height = 36, fps = 30, duration = 1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	s: Script
	defer unload(&s)
	ok := load(&s, path)
	testing.expectf(t, ok == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
}

// 3D vectors and paths: the vec3 helpers on { x, y, z } lists; a path passes
// through its points, ends where it ends (open) or comes back (closed),
// travels at an even speed and eases its fraction.
@(test)
test_std_vec3_and_paths :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local function near(a, b, e) return math.abs(a - b) < (e or 1e-9) end
local function same(a, b, e) return near(a[1], b[1], e) and near(a[2], b[2], e) and near(a[3], b[3], e) end
assert(same(vec3_add({ 1, 2, 3 }, { 4, 5, 6 }), { 5, 7, 9 }) and same(vec3_sub({ 4, 5, 6 }, { 1, 2, 3 }), { 3, 3, 3 }))
assert(same(vec3_scale({ 1, -2, 3 }, 2), { 2, -4, 6 }) and same(vec3_lerp({ 0, 0, 0 }, { 2, 4, 6 }, 0.25), { 0.5, 1, 1.5 }))
assert(vec3_dot({ 1, 2, 3 }, { 4, 5, 6 }) == 32 and same(vec3_cross({ 1, 0, 0 }, { 0, 1, 0 }), { 0, 0, 1 }))
assert(vec3_length({ 3, 4, 0 }) == 5 and vec3_distance({ 1, 1, 1 }, { 1, 4, 5 }) == 5)
assert(same(vec3_normalize({ 0, 0, 2 }), { 0, 0, 1 }) and same(vec3_normalize({ 0, 0, 0 }), { 0, 0, 0 }))
-- turned as a mesh's rotation turns it: a quarter about z takes x to y; X then Y then Z as
-- three.js (Rx Ry Rz: a quarter about y takes x to -z, then a quarter about x takes that to y)
assert(same(vec3_apply_euler({ 1, 0, 0 }, { 0, 0, math.pi / 2 }), { 0, 1, 0 }, 1e-9))
assert(same(vec3_apply_euler({ 1, 0, 0 }, { math.pi / 2, math.pi / 2, 0 }), { 0, 1, 0 }, 1e-9))
assert(same(vec3_apply_euler({ 0, 1, 0 }, { 0, 0, -0.95 }), { math.sin(0.95), math.cos(0.95), 0 }, 1e-9))

local P = { { 0, 0, 0 }, { 4, 0, 0 }, { 4, 0, 3 }, { 10, 2, 3 } }
assert(same(path_at(P, 0), P[1], 1e-6) and same(path_at(P, 1), P[4], 1e-6) and same(path_at(P, 2), P[4], 1e-6))
-- even speed: equal steps of t cover about equal distances (as chords: a
-- little less where the path turns)
local steps = {}
for i = 1, 20 do steps[i] = vec3_distance(path_at(P, (i - 1) / 20), path_at(P, i / 20)) end
local lo, hi = math.huge, 0
for _, d in ipairs(steps) do lo, hi = math.min(lo, d), math.max(hi, d) end
assert(hi / lo < 1.1, hi / lo)
-- it passes through the inner points
local closest = math.huge
for i = 0, 400 do closest = math.min(closest, vec3_distance(path_at(P, i / 400), P[3])) end
assert(closest < 0.05, closest)
-- closed: t wraps, 1 is back at the start
local C = { { 1, 0, 0 }, { 0, 0, 1 }, { -1, 0, 0 }, { 0, 0, -1 } }
assert(same(path_at(C, 1, { closed = true }), C[1], 1e-6) and same(path_at(C, 1.25, { closed = true }), path_at(C, 0.25, { closed = true }), 1e-9))
-- the tangent: along the first segment at the start, unit length
local d = path_tangent(P, 0)
assert(near(vec3_length(d), 1, 1e-6) and d[1] > 0.99, d[1])
-- easing reshapes t: ease_in starts slower than linear
assert(vec3_distance(P[1], path_at(P, 0.2, { easing = ease_in })) < vec3_distance(P[1], path_at(P, 0.2)))
assert(not pcall(path_at, { { 0, 0, 0 } }, 0.5))

video { width = 64, height = 36, fps = 30, duration = 1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	s: Script
	defer unload(&s)
	ok := load(&s, path)
	testing.expectf(t, ok == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
}

// A scene with `transition` gets its overlap from the transition's duration
// (unless it has one) and a wrapped render; the previous scene leaves by it.
@(test)
test_std_scene_transition :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
video { width = 64, height = 36, fps = 30 }
scene { "A", duration = 2, render = function(f) end }
scene { "B", duration = 2, transition = { "fade", duration = 0.5 }, render = function(f) end }
scene { "C", duration = 1, overlap = { previous = 0.25 }, transition = { "wipe", duration = 1 }, render = function(f) end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	s: Script
	defer unload(&s)
	ok := load(&s, path)
	testing.expectf(t, ok == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	testing.expect_value(t, len(s.video.scenes), 3)
	testing.expect_value(t, s.video.scenes[1].overlap.previous, 0.5)
	testing.expect_value(t, s.video.scenes[2].overlap.previous, 0.25)
}

// `props`: JSON objects merged in order (objects to tables, arrays from 1,
// integers stay integers, null is nil), then `key=value` arguments; and
// json_decode, which reads JSON text the same way.
@(test)
test_props :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
assert(props.title == "From set", props.title)
assert(math.type(props.count) == "integer" and props.count == 3)
assert(props.ratio == 0.5 and props.yes == true and props.no == false and props.none == nil)
assert(#props.list == 3 and props.list[1] == 1 and props.list[3].k == "v")
assert(props.nested.inner.deep == "x" and props.nested.empty ~= nil)
assert(props.base == "kept" and props.over == "second")
assert(math.type(props.size) == "integer" and props.size == 40 and props.zip == "007" and props.big == 2e3)
assert(arg.title == "From set" and arg.size == "40" and arg[1] == "pos")
-- json_decode reads JSON the same way; invalid JSON is a Lua error
local j = json_decode('{"color": {"brand": "#0ea5e9"}, "space": [4, 8.5], "none": null}')
assert(j.color.brand == "#0ea5e9" and math.type(j.space[1]) == "integer" and j.space[2] == 8.5 and j.none == nil)
assert(json_decode("[]") ~= nil and json_decode("3") == 3)
local ok, msg = pcall(json_decode, '{"a": ')
assert(not ok and msg:find("json_decode: invalid JSON", 1, true), msg)
video { width = 10, height = 10, fps = 30, duration = 1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	props := []string {
		`{"title": "From file", "base": "kept", "over": "first", "count": 3, "ratio": 0.5, "yes": true, "no": false, "none": null,
		  "list": [1, 2, {"k": "v"}], "nested": {"inner": {"deep": "x"}, "empty": {}}}`,
		`{"over": "second"}`,
	}
	s: Script
	defer unload(&s)
	ok := load(&s, path, {"title=From set", "size=40", "zip=007", "big=2e3", "pos"}, nil, nil, props)
	testing.expectf(t, ok == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))

	// Not an object, or not JSON: the load fails naming props.
	bad: Script
	defer unload(&bad)
	testing.expect_value(t, load(&bad, path, nil, nil, nil, {`[1, 2]`}), Error.Props_Not_Object)
	testing.expect_value(t, error_message(bad.failure, context.temp_allocator), `props: the JSON must be an object, e.g. {"title": "Hello"}`)
	testing.expect_value(t, load(&bad, path, nil, nil, nil, {`{"a": `}), Error.Props_Json)
}

@(test)
test_scalar_value :: proc(t: ^testing.T) {
	testing.expect_value(t, scalar_value("42").(json.Integer), 42)
	testing.expect_value(t, scalar_value("-7").(json.Integer), -7)
	testing.expect_value(t, scalar_value("1.5").(json.Float), 1.5)
	testing.expect_value(t, scalar_value("2e3").(json.Float), 2000)
	testing.expect_value(t, scalar_value("0").(json.Integer), 0)
	for s in ([]string{"", "007", "1_000", "0x10", "1.", ".5", "1e", "inf", "nan", "12 ", "-", "#ff0000", "3 apples"}) {
		str, is_string := scalar_value(s).(json.String)
		testing.expectf(t, is_string && str == s, "%q should stay a string", s)
	}
}

// lottie{} / lottie(f, ...) and lottie_info: a red square moving 20 units
// over a 1 s animation at 10 fps, drawn by the scene's clock and a
// sequence's.
@(test)
test_lottie_api :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local ANIM = [[{"v": "5.7.0", "fr": 10, "ip": 0, "op": 10, "w": 40, "h": 20, "markers": [{"cm": "mid", "tm": 5, "dr": 0}],
  "layers": [{"ty": 1, "ind": 1, "ip": 0, "op": 10, "sc": "#ff0000", "sw": 20, "sh": 20,
    "ks": {"p": {"a": 1, "k": [{"t": 0, "s": [0, 0]}, {"t": 10, "s": [20, 0]}]}}},
   {"ty": 5, "nm": "Title", "ind": 2, "ip": 0, "op": 10, "ks": {"p": {"a": 0, "k": [100, 100]}},
    "t": {"d": {"k": [{"t": 0, "s": {"t": "x", "s": 10, "fc": [0, 0, 0], "lh": 12}}]}, "a": []}}]}]]
video { width = 40, height = 40, fps = 10, background = "#ffffff" }
scene { "Intro", duration = 1, render = function(f) end }
scene { "Main", duration = 1, render = function(f)
  local info = lottie_info { data = ANIM }
  assert(info.width == 40 and info.fps == 10 and info.frames == 10 and info.duration == 1)
  assert(#info.markers == 1 and info.markers[1].name == "mid" and info.markers[1].time == 0.5)
  assert(lottie_info("missing.json") == nil)
  lottie { data = ANIM, overrides = { ["Title"] = { text = "Hello" } } }
  sequence(f, 0.5, nil, function(g) lottie(g, { data = ANIM, y = 20, loop = false }) end)
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	// Video frame 17: the scene's frame 7 (square at x = 14), the
	// sequence's frame 2 (x = 4).
	px := om.render_frame(&r, 17)
	at :: proc(px: []u8, x, y: int) -> [4]u8 {
		i := (y * 40 + x) * 4
		return {px[i], px[i + 1], px[i + 2], px[i + 3]}
	}
	testing.expect_value(t, at(px, 12, 10), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(px, 16, 10), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(px, 2, 30), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(px, 6, 30), [4]u8{255, 0, 0, 255})
	// Only the expected miss is reported.
	for d in r.ctx.diagnostics {
		testing.expectf(t, d.severity < .Error || om.diagnostic_key(d, context.temp_allocator) == "missing_media:missing.json", "unexpected: %s", om.diagnostic_message(d, context.temp_allocator))
	}
}

// A multipass program from Lua: Common, a pass from a file beside the
// script, buffer channels (itself: the previous frame) and a group channel;
// a channel naming a missing buffer is an error at the channel's use.
@(test)
test_shader_multipass_api :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	image_path, _ := filepath.join({dir, "image.glsl"}, context.temp_allocator)
	src := `
video { width = 20, height = 10, fps = 10, duration = 2, background = "#000", render = function(f)
  shader(f, { x = 0, y = 0, w = 20, h = 10, shadertoy = {
    common = "#define STEP 0.1",
    buffer_a = { source = "void mainImage(out vec4 o, in vec2 p) { vec2 uv = p / iResolution.xy; o = texture(iChannel0, uv) + vec4(STEP, 0.0, 0.0, 0.0) + texture(iChannel1, uv).a * vec4(0.0, 0.0, 1.0, 0.0); }",
      channels = { "buffer_a", function() rect { x = 10, y = 0, w = 10, h = 10, fill = "#fff" } end } },
    image = { src = "image.glsl", channels = { "buffer_a" } } } })
  shader(f, { x = 0, y = 0, w = 1, h = 1, shadertoy = {
    image = { source = "void mainImage(out vec4 o, in vec2 p) {\n  o = texture(iChannel2, p);\n}", channels = { [3] = "buffer_c" } } } })
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	image := "void mainImage(out vec4 o, in vec2 p) { o = texture(iChannel0, p / iResolution.xy); }"
	testing.expect(t, os.write_entire_file(image_path, transmute([]u8)image) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	// Frame 3 (a seek: frames 0..2 run first): four steps of 0.1 in red;
	// blue where the group's square is.
	px := om.render_frame(&r, 3)
	testing.expect_value(t, px[(5 * 20 + 2) * 4 + 0], u8(102))
	testing.expect_value(t, px[(5 * 20 + 2) * 4 + 2], u8(0))
	testing.expect_value(t, px[(5 * 20 + 15) * 4 + 2], u8(255))
	bad := false
	for d in r.ctx.diagnostics {
		if d.severity == .Error && om.diagnostic_message(d, context.temp_allocator) == "shader <inline>: Image:2:15: iChannel2 reads Buffer C, which the program does not have" {
			bad = true
		} else {
			testing.expectf(t, d.severity < .Error, "unexpected: %s", om.diagnostic_message(d, context.temp_allocator))
		}
	}
	testing.expect(t, bad)
}

// The passes form: an SkSL pass reading an earlier one, an SkSL pass
// reading its own last frame (a seek runs the frames before; the output is
// read, so the box shows its buffer), SkSL feeding a GLSL pass by sampler
// name, and a reference to a pass the program lacks (an error at the
// channel's use) or an output it lacks.
@(test)
test_shader_passes_api :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	frag_path, _ := filepath.join({dir, "show.frag"}, context.temp_allocator)
	src := `
local HALF = "half4 main(float2 p) { return half4(0.25, 0.0, 0.0, 1.0); }"
local DOUBLE = "uniform shader uIn;\nhalf4 main(float2 p) { return uIn.eval(p) * 2.0; }"
local ACC = "uniform shader uLast;\nuniform float uStep;\nhalf4 main(float2 p) { return uLast.eval(p) + half4(uStep, 0.0, 0.0, 0.0) + half4(0.0, 0.0, 0.0, 0.1); }"
local LEFT = "uniform float3 iResolution;\nhalf4 main(float2 p) { return p.x < iResolution.x * 0.5 ? half4(0.0, 1.0, 0.0, 1.0) : half4(0.0, 0.0, 0.0, 1.0); }"
video { width = 20, height = 40, fps = 10, duration = 2, background = "#000", render = function(f)
  shader(f, { x = 0, y = 0, w = 20, h = 10, passes = {
    { name = "half", sksl = HALF },
    { name = "double", sksl = DOUBLE, inputs = { uIn = "half" } } } })
  shader(f, { x = 0, y = 10, w = 20, h = 10, uniforms = { uStep = 0.1 }, passes = {
    { name = "acc", sksl = ACC, inputs = { uLast = { previous = "acc" } } } } })
  shader(f, { x = 0, y = 20, w = 20, h = 10, output = "show", passes = {
    { name = "left", sksl = LEFT },
    { name = "show", src = "show.frag", inputs = { uSrc = "left" } } } })
  shader(f, { x = 0, y = 30, w = 1, h = 1, passes = {
    { name = "a", sksl = DOUBLE, inputs = { uIn = { previous = "nope" } } } } })
  shader(f, { x = 0, y = 30, w = 1, h = 1, output = "nope", passes = { { name = "a", sksl = HALF } } })
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	frag := "#version 300 es\nprecision highp float;\nlayout(location = 0) in vec2 uv;\nlayout(location = 0) out vec4 color;\nuniform sampler2D uSrc;\nvoid main() { color = texture(uSrc, uv); }\n"
	testing.expect(t, os.write_entire_file(frag_path, transmute([]u8)frag) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	at :: proc(px: []u8, x, y: int) -> [4]u8 {
		i := (y * 20 + x) * 4
		return {px[i], px[i + 1], px[i + 2], px[i + 3]}
	}
	// Frame 3, a seek: frames 0..2 run first, so the accumulator has
	// four steps of 0.1 in red.
	px := om.render_frame(&r, 3)
	testing.expect_value(t, at(px, 10, 5), [4]u8{128, 0, 0, 255})
	testing.expect_value(t, at(px, 10, 15), [4]u8{102, 0, 0, 255})
	testing.expect_value(t, at(px, 2, 25), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, at(px, 17, 25), [4]u8{0, 0, 0, 255})
	no_pass, no_output := false, false
	for d in r.ctx.diagnostics {
		msg := om.diagnostic_message(d, context.temp_allocator)
		switch msg {
		case "shader <inline>: a:2:31: uIn reads nope, which the program does not have":
			no_pass = true
		case `invalid shader output "nope" (want a)`:
			no_output = true
		case:
			testing.expectf(t, d.severity < .Error, "unexpected: %s", msg)
		}
	}
	testing.expect(t, no_pass && no_output)
}

// captions_load (text and word lists) and caption_pages at load,
// caption_words while rendering.
@(test)
test_captions_api :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
assert(captions_load("a.vtt", "WEBVTT\n\n00:00.000 --> 00:01.000\none <00:00.200>two three\n") == 3)
assert(captions_load("w", { { text = "x", start = 0, stop = 0.5 }, { text = "y", start = 0.5, stop = 1 } }) == 2)
local pages = caption_pages("w", { max_words = 1 })
assert(#pages == 2 and pages[2].text == "y" and pages[2].start == 0.5 and pages[2].words[1].stop == 1)
assert(caption_pages("a.vtt")[1].text == "one two three")
video { width = 40, height = 40, fps = 10, duration = 2, render = function(f)
  local ws = caption_words(0.5, "a.vtt")
  assert(#ws == 3 and ws.page == 1 and ws.time == 0.5)
  assert(ws[1].text == "one" and math.abs(ws[1].stop - 0.2) < 1e-6 and ws[1].progress == 1 and not ws[1].active)
  assert(ws[2].active and math.abs(ws[2].progress - 0.75) < 1e-3 and ws[3].progress == 0)
  assert(caption_words(1.5, "a.vtt") == nil)
  assert(caption_words(1.1, "a.vtt", { hold = 0.2 }) ~= nil)
  captions(f, { src = "w", x = 0, y = 20, w = 40, size = 10, highlight = "box" })
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 3)
	for d in r.ctx.diagnostics {
		testing.expectf(t, d.severity < .Error, "unexpected: %s", om.diagnostic_message(d, context.temp_allocator))
	}
}

// The calls that set the video up (scenes, tracks, cues, media) raise a Lua
// error while rendering instead of changing what the render reads.
@(test)
test_load_only_while_rendering :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
video { width = 40, height = 40, fps = 10 }
scene { "S", duration = 1, render = function(f)
  local calls = {
    video = function() video { width = 80, height = 80, fps = 30 } end,
    scene = function() scene { "A", duration = 1 } end,
    cue = function() cue("x", 0.5) end,
    physics = function() physics { duration = 1, bodies = {} } end,
    physics3d = function() physics3d { duration = 1, bodies = {} } end,
    audio_add = function() audio_add("n", { { 0, 0 } }) end,
    captions_load = function() captions_load("c", { { text = "a", start = 0, stop = 1 } }) end,
    say = function() say("a", "hi") end,
  }
  for name, call in pairs(calls) do
    local ok, err = pcall(call)
    assert(not ok and err:find(name .. "() works at load, not while rendering a frame", 1, true), name)
    assert(err:find("^video%.lua:%d+: "), err) -- the script's line, not std.lua's
  end
  rect { x = 0, y = 0, width = 40, height = 40, fill = "#fff" }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 3)
	// The render ran to its rect: no Lua error, no empty frame.
	for d in r.ctx.diagnostics {
		testing.expectf(t, false, "unexpected: %s", om.diagnostic_message(d, context.temp_allocator))
	}
	testing.expect_value(t, len(s.scenes), 1)
	testing.expect_value(t, len(s.cues), 0)
	testing.expect_value(t, s.video.width, 40)
	testing.expect(t, "n" not_in media.audio && "c" not_in media.captions)
}

// Script lines are named from the script's folder, cleaned, however the
// script's path is spelled: a scene made in a required file, a cue in a
// dofile'd one, and the files' own source names.
@(test)
test_source_names :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	scenes, _ := filepath.join({dir, "scenes"}, context.temp_allocator)
	testing.expect(t, os.make_directory(scenes) == nil)
	files := [?][2]string {
		{"video.lua", `video { width = 40, height = 40, fps = 10 }
require("scenes.a")
local b = dofile("scenes/../scenes/b.lua")
assert(b.source == "@scenes/b.lua", b.source)
`},
		{"scenes/a.lua", `scene { "A", duration = 1 }`},
		{"scenes/b.lua", `cue("b", 0.5)
return { source = debug.getinfo(1, "S").source }`},
	}
	for f in files {
		path, _ := filepath.join({dir, f[0]}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)f[1]) == nil)
	}
	for spelled in ([?]string{"video.lua", "scenes/../video.lua", "./scenes/./../video.lua"}) {
		path := fmt.tprintf("%s/%s", dir, spelled)
		s: Script
		defer unload(&s)
		testing.expectf(t, load(&s, path) == nil, "load %s failed: %s", spelled, error_message(s.failure, context.temp_allocator))
		testing.expect_value(t, len(s.scenes), 1)
		testing.expect_value(t, len(s.cues), 1)
		if len(s.scenes) == 1 && len(s.cues) == 1 {
			testing.expect_value(t, s.scenes[0].source, "scenes/a.lua:1")
			testing.expect_value(t, s.cues[0].at, "scenes/b.lua:1")
		}
	}
}

// The SVG 1.1 filter primitives from Lua: a dilated square grows, a
// component transfer zeroes red, turbulence fills its region, lighting
// lights a flat surface fully, and every primitive parses without errors.
@(test)
test_filter_primitives :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
video { width = 80, height = 40, fps = 10, background = "#000000" }
scene { "Main", duration = 1, render = function(f)
  local user = function(x, y, w, h) return { x = x, y = y, w = w, h = h, units = "userSpaceOnUse" } end
  group({ filter = { { "morphology", operator = "dilate", radius = 2 }, region = user(0, 0, 20, 20) } }, function()
    rect { x = 8, y = 8, w = 4, h = 4, fill = "#ffffff" }
  end)
  group({ filter = { { "component_transfer", r = { type = "linear", slope = 0 }, g = { type = "table", values = {0, 1} } },
                     region = user(20, 0, 20, 20) } }, function()
    rect { x = 20, y = 0, w = 20, h = 20, fill = "#ffff00" }
  end)
  group({ filter = { { "turbulence", type = "fractalNoise", base_frequency = 0.1, octaves = 2, seed = 3 },
                     region = user(40, 0, 20, 20) } }, function()
    rect { x = 41, y = 1, w = 1, h = 1, fill = "#ffffff" }
  end)
  group({ filter = { { "diffuse_lighting", color = "#ffffff", light = { "distant", elevation = 90 } },
                     region = user(60, 0, 20, 20) } }, function()
    rect { x = 61, y = 1, w = 1, h = 1, fill = "#ffffff" }
  end)
  group({ filter = {
    { "turbulence", base_frequency = 0.2, result = "n" },
    { "displacement_map", input = "SourceGraphic", input2 = "n", scale = 4, x_channel = "R", y_channel = "G", result = "d" },
    { "convolve_matrix", kernel = {0, -1, 0, -1, 5, -1, 0, -1, 0}, edge = "wrap" },
    { "specular_lighting", surface_scale = 2, exponent = 8, light = { "spot", x = 10, y = 30, z = 40, points_at = {10, 30, 0}, cone = 30 } },
    { "tile", subregion = {0, 20, 40, 20} },
    { "image", src = "missing.png" },
    region = user(0, 20, 40, 20) } }, function()
    rect { x = 5, y = 25, w = 10, h = 10, fill = "#ff0000" }
  end)
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	px := om.render_frame(&r, 0)
	at :: proc(px: []u8, x, y: int) -> [4]u8 {
		i := (y * 80 + x) * 4
		return {px[i], px[i + 1], px[i + 2], px[i + 3]}
	}
	// Dilated by 2: (6, 6) .. (13, 13) white, (5, 10) black.
	testing.expect_value(t, at(px, 6, 10), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(px, 13, 13), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, at(px, 5, 10), [4]u8{0, 0, 0, 255})
	// Red to 0, green through an identity table.
	testing.expect_value(t, at(px, 30, 10), [4]u8{0, 255, 0, 255})
	// Noise everywhere in its region, varying.
	a, b := at(px, 45, 5), at(px, 55, 15)
	testing.expect(t, a != b && a != [4]u8{0, 0, 0, 255})
	// Lit from straight above: full white.
	testing.expect_value(t, at(px, 70, 10), [4]u8{255, 255, 255, 255})
	for d in r.ctx.diagnostics {
		testing.expectf(t, d.severity < .Error || om.diagnostic_key(d, context.temp_allocator) == "missing_media:missing.png", "unexpected: %s", om.diagnostic_message(d, context.temp_allocator))
	}
}

// Misspelled options and globals are reported: unused fields with the
// closest field read, a forgotten stop on animate's last key, undefined
// globals as errors; `require` returns the module only.
@(test)
test_script_checks :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	mod, _ := filepath.join({dir, "mod.lua"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(mod, transmute([]u8)string("return 7")) == nil)
	src := `
local parts = { require("mod") }
assert(#parts == 1 and parts[1] == 7)
local ok, err = pcall(function() return eas_out end)
assert(not ok and err:find("undefined global 'eas_out' %(did you mean 'ease_out'%?%)"), err)
assert(rawget(_G, "not_set") == nil)
stagger(2, 0.1, { n = 3, form = "center" })
animate(1, { { 0, 0.5, 0, 1 }, { 0.6, nil, 1, 0, ease_in } })
animate(1, { { 0, nil, 0, 1, spring { stiffness = 200, damping = 20 } } })
video { width = 100, height = 90, fps = 30, backgroud = "#000",
  audio = { { "a.wav", gain = -6 } } }
scene { "A", duraton = 1, duration = 1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	want := [?]string {
		"video.lua:7: `stagger.form` is not used (did you mean `from`?)",
		"video.lua:8: animate's last key has no stop, so it jumps to its `to` at 0.6s (give it a stop; stop = start for a jump)",
		"video.lua:10: `audio track.gain` is not used (did you mean `gain_db`?)",
		"video.lua:10: `video.backgroud` is not used (did you mean `background`?)",
		"video.lua:12: `scene.duraton` is not used (did you mean `duration`?)",
	}
	testing.expect_value(t, len(s.load_problems), len(want))
	for d, i in s.load_problems {
		if i < len(want) {
			testing.expect_value(t, om.diagnostic_message(d, context.temp_allocator), want[i])
		}
	}
}

// Option tables nested in a checked one are checked too: a track's ducking
// and start time, the limiter, a scene's overlap and duration, caption
// words at load; a filter's shadow, list, region and its primitives'
// light, transfer and subregion tables while rendering.
@(test)
test_nested_option_checks :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
captions_load("w", { { text = "x", start = 0, stpo = 0.5 } })
video { width = 40, height = 40, fps = 10, limiter = { ceiling = -1 },
  audio = { { "a.wav", ducked = { dept_db = -9 }, start = { seconds = 1, frmes = 2 } } } }
scene { "A", duration = { frames = 10, secs = 1 }, overlap = { previous = 0.5, nxt = 0 }, render = function(f)
  group({ shadow = { dx = 1, blurr = 2 }, srgb = true,
    filter = { { "diffuse_lighting", light = { "distant", elevaton = 90 } },
      { "component_transfer", r = { type = "linear", slop = 0 }, subregion = { x = 0, y = 0, w = 10, hh = 10 } },
      region = { x = 0, y = 0, w = 40, h = 40, unit = "user" }, srgbb = true } }, function()
    rect { x = 0, y = 0, w = 40, h = 40, fill = "#fff" }
  end)
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	want := [?]string {
		"video.lua:2: `captions_load word.stpo` is not used (did you mean `stop`?)",
		"video.lua:3: `time.frmes` is not used (did you mean `frames`?)",
		"video.lua:3: `ducked.dept_db` is not used (did you mean `depth_db`?)",
		"video.lua:3: `limiter.ceiling` is not used (did you mean `ceiling_db`?)",
		"video.lua:5: `duration.secs` is not used",
		"video.lua:5: `overlap.nxt` is not used (did you mean `next`?)",
	}
	testing.expect_value(t, len(s.load_problems), len(want))
	for d, i in s.load_problems {
		got := om.diagnostic_message(d, context.temp_allocator)
		testing.expectf(t, i < len(want) && got == want[i], "load problem %d: %s", i, got)
	}
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)
	frame_want := [?]string {
		"video.lua:6: `shadow.blurr` is not used (did you mean `blur`?)",
		"video.lua:6: `filter.srgbb` is not used (did you mean `srgb`?)",
		"video.lua:6: `region.unit` is not used (did you mean `units`?)",
		"video.lua:6: `light.elevaton` is not used (did you mean `elevation`?)",
		"video.lua:6: `transfer.slop` is not used (did you mean `slope`?)",
		"video.lua:6: `subregion.hh` is not used (did you mean `h`?)",
	}
	got := make([dynamic]string, context.temp_allocator)
	for d in r.ctx.diagnostics {
		append(&got, om.diagnostic_message(d, context.temp_allocator))
	}
	for w in frame_want {
		testing.expectf(t, slice.contains(got[:], w), "missing %q in %v", w, got[:])
	}
}

// say() for a line that can't be synthesized (an unknown voice: no engine,
// no download): a silent placeholder with estimated times and a
// `tts_unavailable` warning, the script still loads. Its clip and its
// captions (a cue per sentence) are in the media; a track playing it with
// no bus goes on the voice bus; say_cue names a word's video time.
@(test)
test_say_unavailable :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local AT = 1.5
local O = { voice = "nobody", seed = 2 }
local line = say("intro", "The keeper climbed the stairs. Then the lamp went dark!", O)
assert(line.ready == false and line.name == "intro" and line.voice == "nobody" and line.seed == 2)
assert(#line.words == 10 and #line.chunks == 2, #line.words .. " words")
assert(line.words[1].text == "The" and line.words[1].estimated and line.words[10].chunk == 2)
assert(line.chunks[2].first == 6 and line.chunks[2].count == 5, line.chunks[2].first)
assert(say("intro", "The keeper climbed the stairs. Then the lamp went dark!", O).duration == line.duration)
assert(not pcall(say, "intro", "Something else.", O))
local LAMP = say_cue(line, AT, "lamp")
assert(math.abs(LAMP - (AT + line.words[8].start)) < 1e-9)
local THE2 = say_cue(line, AT, "the", { nth = 3, name = "the_lamp" })
assert(THE2 == AT + line.words[7].start)
assert(not pcall(say_cue, line, AT, "the", { nth = 4 }))
local pages = caption_pages("intro")
assert(#pages == 2 and pages[2].words[1].text == "Then", #pages)
local shifted = caption_pages("intro", { start = AT })
assert(math.abs(shifted[1].start - (AT + pages[1].start)) < 1e-6)
video { width = 100, height = 100, fps = 30, duration = { audio = "intro" }, buses = { speech = { kind = "voice" } },
  audio = { { "intro", start = AT } } }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)

	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	ok := load(&s, path, nil, &media)
	testing.expectf(t, ok == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))

	testing.expect_value(t, len(s.load_problems), 1)
	if len(s.load_problems) == 1 {
		testing.expect_value(t, s.load_problems[0].code, om.Diagnostic_Code.Tts_Unavailable)
		testing.expect_value(t, s.load_problems[0].a, "intro")
	}
	testing.expect(t, "intro" in media.audio)
	cap := &media.captions["intro"]
	testing.expect_value(t, om.caption_count(cap), 10)
	testing.expect(t, cap.segmented)
	testing.expect_value(t, cap.cues[5], 1)
	testing.expect_value(t, om.caption_word(cap, 5), "Then")
	testing.expect_value(t, s.video.audio[0].bus, "speech")
	testing.expect(t, !s.video.audio[0].voice)

	l, have := said_line(&s, "intro")
	testing.expect(t, have && !l.ready && len(l.words) == 10)
}

// A line's captions: its words with their times, a cue per sentence, even
// inside one chunk.
@(test)
test_line_captions :: proc(t: ^testing.T) {
	two := speech.Line {
		words  = {{0, 0.2, 3, 0, false}, {0.2, 0.4, 6, 0, false}, {0.7, 0.9, 11, 0, false}},
		chunks = {{0, 0.9, 26, 0, 3}},
		text   = transmute([]u8)string("OnetwoThreeOne two. Three!"),
	}
	c1 := line_captions(two)
	defer om.captions_destroy(&c1)
	testing.expect_value(t, c1.cues[0], 0)
	testing.expect_value(t, c1.cues[1], 0)
	testing.expect_value(t, c1.cues[2], 1)

	l := speech.placeholder("One two. Three!")
	defer speech.line_destroy(&l)
	l.words[2].start, l.words[2].stop = 1.25, 1.5
	c := line_captions(l)
	defer om.captions_destroy(&c)
	testing.expect_value(t, om.caption_count(&c), 3)
	testing.expect_value(t, om.caption_word(&c, 2), "Three")
	testing.expect_value(t, c.starts[2], 1250)
	testing.expect_value(t, c.stops[2], 1500)
	testing.expect_value(t, c.cues[1], 0)
	testing.expect_value(t, c.cues[2], 1)
	testing.expect(t, c.segmented)
}

// view3d{} in three.js's names: the tables become the node's camera,
// lights, meshes (geometry parameters in constructor order, least counts)
// and materials; misspelled or misplaced keys warn in every nested table,
// unknown types are invalid values and leave their entry out; the frame
// draws the lit red box.
@(test)
test_view3d_api :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
video { width = 64, height = 48, fps = 10, background = "#000000" }
scene { "A", duration = 1, render = function(f)
  view3d {
    tone_mapping = "agx",
    tone_mapping_exposure = 1.2,
    fog = { type = "FogExp2", color = "#102030", density = 0.05 },
    camera = { position = { 0, 0, 4 }, fov = 45, fvo = 1 },
    lights = {
      { type = "AmbientLight", intensity = 0.5, ground_color = "#fff" },
      { type = "DirectionalLight", color = 0xffffff, intensity = 3, position = { 1, 2, 3 }, cast_shadow = true,
        shadow = { map_size = 256, baias = 0 } },
      { type = "SpotLight", color = "#fff", intensity = 2, position = { 0, 3, 2 }, angle = 0.5, penumbra = 0.2, cast_shadow = true },
      { type = "RectAreaLight", color = "#fff" },
    },
    meshes = {
      { geometry = { type = "BoxGeometry", width = 2, height = 1.5, width_segments = 0 },
        material = { color = "#ff0000", roughness = 0.5, metalnes = 1 }, rotation = { 0.1, 0.2, 0 }, scale = 1.5, cast_shdow = true },
      { geometry = { type = "SphereGeometry", radius = 0.5, radial = 3 }, position = { 1, 0, 0 },
        material = { type = "MeshBasicMaterial", color = "#00ff00", roughness = 1 },
        instances = { { position = { -0.5, 0, 0 }, scale = 0.8, color = "#ffff00" } } },
      { geometry = { type = "LineGeometry", points = { { -1, -1, 0 }, { 1, 1, 0 } }, closed = true },
        material = { linewidth = 0.04, size_attenuation = false } },
      { geometry = { type = "PointsGeometry", points = { 0, 0, 0, 0.5, 0.5, 0 } },
        material = { size = 0.08, color = "#00ffff" } },
      { geometry = { type = "Cube" } },
    },
    models = { { src = "duck.glb", animaton = "Walk" } },
  }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	px := om.render_frame(&r, 0)

	v: om.View3d
	for n in r.ctx.tree.nodes {
		if node, ok := n.kind.(om.View3d); ok {
			v = node
		}
	}
	testing.expect_value(t, v.w, 64)
	testing.expect_value(t, v.camera.fov, 45)
	testing.expect_value(t, v.tone_mapping, o3d.Tone_Mapping.AgX)
	testing.expect_value(t, v.tone_mapping_exposure, 1.2)
	testing.expect_value(t, v.fog.kind, o3d.Fog_Kind.Exp2)
	testing.expect_value(t, v.fog.density, 0.05)
	testing.expect_value(t, len(v.lights), 3)
	testing.expect_value(t, len(v.meshes), 4)
	if len(v.lights) == 3 && len(v.meshes) == 4 {
		testing.expect_value(t, v.lights[1].color, [3]f32{1, 1, 1})
		testing.expect(t, v.lights[1].cast_shadow && v.lights[1].shadow.map_size == 256)
		testing.expect_value(t, v.lights[0].decay, 2)
		testing.expect_value(t, v.lights[2].kind, o3d.Light_Kind.Spot)
		testing.expect_value(t, v.lights[2].angle, 0.5)
		testing.expect_value(t, v.lights[2].penumbra, 0.2)
		testing.expect(t, v.lights[2].cast_shadow)
		box := v.meshes[0]
		testing.expect_value(t, box.geometry.kind, .Box)
		testing.expect_value(t, box.geometry.params, [7]f32{2, 1.5, 1, 1, 1, 1, 0})
		testing.expect_value(t, box.scale, [3]f32{1.5, 1.5, 1.5})
		testing.expect_value(t, box.material.color, [3]f32{1, 0, 0})
		testing.expect_value(t, box.material.flags, o3d.Material_Flags{})
		testing.expect_value(t, v.meshes[1].material.flags, o3d.Material_Flags{.Basic})
		testing.expect_value(t, len(v.meshes[1].instances), 1)
		if len(v.meshes[1].instances) == 1 {
			testing.expect(t, v.meshes[1].instances[0].has_color)
			testing.expect_value(t, v.meshes[1].instances[0].color, [3]f32{1, 1, 0})
		}
		testing.expect_value(t, v.meshes[2].path_kind, om.Path_Kind.Polyline)
		testing.expect(t, v.meshes[2].path_closed)
		testing.expect_value(t, len(v.meshes[2].points), 2)
		testing.expect_value(t, v.meshes[2].material.mode, o3d.Draw_Mode.Lines)
		testing.expect_value(t, v.meshes[2].material.flags, o3d.Material_Flags{.Basic, .No_Size_Attenuation})
		testing.expect_value(t, v.meshes[3].path_kind, om.Path_Kind.Points)
		testing.expect_value(t, len(v.meshes[3].points), 2)
		testing.expect_value(t, v.meshes[3].material.mode, o3d.Draw_Mode.Points)
	}
	want := [?]string {
		"video.lua:4: `camera.fvo` is not used (did you mean `fov`?)",
		"video.lua:4: `light.ground_color` is not used",
		"video.lua:4: `shadow.baias` is not used (did you mean `bias`?)",
		`invalid light type "RectAreaLight" (want AmbientLight, HemisphereLight, DirectionalLight, PointLight or SpotLight)`,
		"video.lua:4: `material.metalnes` is not used (did you mean `metalness`?)",
		"video.lua:4: `mesh.cast_shdow` is not used (did you mean `cast_shadow`?)",
		"video.lua:4: `geometry.radial` is not used (did you mean `radius`?)",
		"video.lua:4: `material.roughness` is not used",
		`invalid geometry type "Cube" (want BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, TorusGeometry, CapsuleGeometry, TubeGeometry, ShapeGeometry, ExtrudeGeometry, LineGeometry, LineSegmentsGeometry or PointsGeometry)`,
		"video.lua:4: `model.animaton` is not used (did you mean `animation`?)",
		`no model "duck.glb" in the media`,
	}
	got := make([dynamic]string, context.temp_allocator)
	for d in r.ctx.diagnostics {
		append(&got, om.diagnostic_message(d, context.temp_allocator))
	}
	testing.expectf(t, len(got) == len(want), "diagnostics: %v", got[:])
	for w in want {
		testing.expectf(t, slice.contains(got[:], w), "missing %q in %v", w, got[:])
	}
	mid := px[(24 * 64 + 32) * 4:][:4]
	testing.expectf(t, mid[0] > 150 && mid[0] > mid[1], "the box: %v", mid)
}

@(test)
test_view3d_shader_material :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_script_shader_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
video { width = 64, height = 48, fps = 10, background = "#000000" }
scene { "A", duration = 1, render = function(f)
  view3d {
    meshes = {
      { geometry = { type = "SphereGeometry", radius = 1 },
        material = {
          type = "ShaderMaterial",
          vertex_shader = "void main() { gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
          fragment_shader = "uniform vec3 uColor; uniform float uAmount; uniform bool uFlag; void main() { gl_FragColor = vec4(uColor * uAmount * (uFlag ? 1.0 : 0.5), 1.0); }",
          uniforms = { uAmount = 0.5, uColor = "#ff00aa", uFlag = true, uVec = { 1, 2, 3 } },
          transparent = true,
          side = "double",
          glsl3 = false,
          roughness = 0.5,
          vertex_shder = "",
        } },
    },
    models = {
      { src = "duck.glb", morphs = { Smile = 0.8, [1] = 0.5 }, material = { type = "MeshBasicMaterial", color = "#00ff00", side = "back", metalness = 1 } },
    },
  }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)

	v: om.View3d
	for n in r.ctx.tree.nodes {
		if node, ok := n.kind.(om.View3d); ok {
			v = node
		}
	}
	testing.expect_value(t, len(v.meshes), 1)
	testing.expect_value(t, len(v.models), 1)
	if len(v.meshes) == 1 {
		m := v.meshes[0]
		testing.expect_value(t, m.material.flags, o3d.Material_Flags{.Transparent})
		testing.expect_value(t, m.material.side, o3d.Side.Double)
		sh, has_sh := m.shader.?
		testing.expect(t, has_sh)
		testing.expect_value(t, sh.glsl3, false)
		testing.expect_value(t, len(sh.uniforms), 4)
		if len(sh.uniforms) == 4 {
			testing.expect_value(t, sh.uniforms[0].name, "uAmount")
			testing.expect_value(t, sh.uniforms[0].value[0], 0.5)
			testing.expect_value(t, sh.uniforms[1].name, "uColor")
			testing.expect(t, abs(sh.uniforms[1].value[0] - 1) < 1e-4 && abs(sh.uniforms[1].value[2] - o3d.srgb_to_linear(f32(0xaa) / 255)) < 1e-4)
			testing.expect_value(t, sh.uniforms[2].name, "uFlag")
			testing.expect_value(t, sh.uniforms[2].value[0], 1)
			testing.expect_value(t, sh.uniforms[3].name, "uVec")
			testing.expect_value(t, len(sh.uniforms[3].value), 3)
		}
	}
	if len(v.models) == 1 {
		over, has_over := v.models[0].material.?
		testing.expect(t, has_over)
		testing.expect_value(t, over.material.flags, o3d.Material_Flags{.Basic})
		testing.expect_value(t, over.material.side, o3d.Side.Back)
		testing.expect_value(t, over.material.color, [3]f32{0, 1, 0})
		testing.expect_value(t, len(v.models[0].morphs), 2)
		if len(v.models[0].morphs) == 2 {
			testing.expect_value(t, v.models[0].morphs[0], o3d.Morph_Weight{index = 0, weight = 0.5})
			testing.expect_value(t, v.models[0].morphs[1], o3d.Morph_Weight{name = "Smile", weight = 0.8})
		}
	}
	want := [?]string {
		"video.lua:4: `material.roughness` is not used",
		"video.lua:4: `material.vertex_shder` is not used (did you mean `vertex_shader`?)",
		"video.lua:4: `material.metalness` is not used",
		"shader ShaderMaterial: uniform `uVec` is not declared",
		`no model "duck.glb" in the media`,
	}
	got := make([dynamic]string, context.temp_allocator)
	for d in r.ctx.diagnostics {
		append(&got, om.diagnostic_message(d, context.temp_allocator))
	}
	testing.expectf(t, len(got) == len(want), "diagnostics: %v", got[:])
	for w in want {
		testing.expectf(t, slice.contains(got[:], w), "missing %q in %v", w, got[:])
	}
}

// Outlines: path data, text and an SVG element as path handles with their
// bounds; a morph's ends are its outlines; a ring-shaped outline body (a
// hole) rests at its height and collides with all of itself; extruded
// outlines draw, and a bevel deeper than the outline's teeth is reported
// (extrude_folded).
@(test)
test_outline_api :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_outline_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	font, _ := filepath.join({dir, "BebasNeue-Regular.ttf"}, context.temp_allocator)
	svg, _ := filepath.join({dir, "mark.svg"}, context.temp_allocator)
	font_data, ferr := os.read_entire_file("assets/fonts/BebasNeue-Regular.ttf", context.temp_allocator)
	testing.expect(t, ferr == nil)
	testing.expect(t, os.write_entire_file(font, font_data) == nil)
	mark := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" width="100" height="100">` +
		`<rect x="0" y="0" width="10" height="10" fill="#f00"/><g id="s" display="none"><path d="M2 2H8V8H2Z"/></g></svg>`
	testing.expect(t, os.write_entire_file(svg, transmute([]u8)mark) == nil)
	src := `
local function near(a, b) return math.abs(a - b) < 0.5 end
local SQ = outline { d = "M0 0H100V100H0Z" }
local x, y, w, h = outline_bounds(SQ)
assert(near(x, 0) and near(y, 0) and near(w, 100) and near(h, 100))
-- an SVG element by id (hidden, as silhouettes are), placed as svg{} would place the file
local S = outline { svg = "mark.svg", id = "s", x = 10, y = 20, w = 200 }
x, y, w, h = outline_bounds(S)
assert(near(x, 50) and near(y, 60) and near(w, 120) and near(h, 120), string.format("%g %g %g %g", x, y, w, h))
local A = outline { "A", font = "Bebas Neue", size = 100, align = "center", baseline = "middle" }
x, y, w, h = outline_bounds(A)
assert(w > 20 and h > 50 and near(x + w / 2, 0), string.format("%g %g %g %g", x, y, w, h))
assert(outline { "A", font = "Bebas Neue", size = 100, align = "center", baseline = "middle" } == A)  -- by content
local M = morph(A, SQ)
assert(morph(A, SQ) == M)
local ax, ay, aw, ah = outline_bounds(morph_at(M, 0))
local bx, by, bw, bh = outline_bounds(morph_at(M, 1))
assert(near(aw, w) and near(ah, h) and near(bw, 100) and near(bh, 100))
-- A 100 px ring (a 60 px hole) dropped on a floor: rests on its edge, centre 50 px up.
local RING = outline { d = "M-50 -50H50V50H-50Z M-30 -30V30H30V-30Z" }
local sim = physics { duration = 2, gravity = 2000, bodies = {
  { static = true, box = { 1000, 40 }, x = 0, y = 520 },
  { name = "ring", outline = RING, x = 0, y = 300 },
} }
local _, ry = physics_at(sim, "ring", 2)
assert(near(ry, 450), tostring(ry))
COMB = outline { d = "M0 0H5V-10H6V0H7V-10H8V0H9V-10H10V0H15V3H0Z" }  -- 1-wide teeth
video { width = 64, height = 64, fps = 10, duration = 0.1, render = function(f)
  view3d { camera = { position = { 0, 0, 30 } }, meshes = {
    { geometry = { type = "ExtrudeGeometry", shape = A, depth = 10, bevel_enabled = false } },
    { geometry = { type = "ExtrudeGeometry", shape = COMB, depth = 1, bevel_size = 0.6, bevel_offset = -0.6 } },
  } }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	testing.expect_value(t, om.media_load_dir(&media, dir), om.Error.None)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	testing.expect_value(t, len(s.load_problems), 0)
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)
	folded := false
	for d in r.ctx.diagnostics {
		folded ||= d.code == .Extrude_Folded
	}
	testing.expect(t, folded)
}

// ShapeGeometry draws from its curves (an exact shape) unless its material
// draws triangles (a wireframe here): a transparent white square covers the
// middle, the background shows outside it.
@(test)
test_view3d_exact_shape :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_exact_shape_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local SQ = outline { d = "M-1 -1H1V1H-1Z" }
video { width = 64, height = 64, fps = 10, duration = 0.1, background = "#000000", render = function(f)
  view3d { camera = { position = { 0, 0, 5 } }, meshes = {
    { geometry = { type = "ShapeGeometry", shape = SQ }, material = { type = "MeshBasicMaterial", color = "#ffffff", transparent = true } },
    { geometry = { type = "ShapeGeometry", shape = SQ }, position = { 0, 0, -50 }, material = { wireframe = true } },
  } }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	px := om.render_frame(&r, 0)
	testing.expect_value(t, len(r.ctx.diagnostics), 0)
	for n in r.ctx.tree.nodes {
		if v, ok := n.kind.(om.View3d); ok && len(v.meshes) == 2 {
			testing.expect_value(t, v.meshes[0].outline.kind, om.Outline_Kind.Exact)
			testing.expect_value(t, v.meshes[1].outline.kind, om.Outline_Kind.Shape)
		}
	}
	mid := px[(32 * 64 + 32) * 4:][:4]
	corner := px[(2 * 64 + 2) * 4:][:4]
	testing.expectf(t, mid[0] > 240 && mid[1] > 240 && mid[2] > 240, "the square: %v", mid)
	testing.expectf(t, corner[0] < 10, "outside it: %v", corner)
}

// physics{} bodies of several shapes: a table on two legs rests on its legs
// (each `shapes` entry placed by its x, y, angle in the body's frame).
@(test)
test_physics_shapes :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_physics_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local sim = shared("table", function()
  return physics { duration = 2, gravity = 2000, bodies = {
    { static = true, box = { 2000, 40 }, x = 500, y = 520 },           -- top at 500
    { name = "table", x = 500, y = 300, shapes = {
      { box = { 200, 20 } },                                             -- the top, about the origin
      { box = { 20, 60 }, x = -90, y = 40 }, { box = { 20, 60 }, x = 90, y = 40 },
      { polygon = { -10, 0, 10, 0, 0, 20 }, x = 0, y = -20, angle = 180 } } },
  } }
end)
local x, y, a = physics_at(sim, "table", 2)
assert(math.abs(y - 430) < 2 and math.abs(a) < 0.5, string.format("rests at %.1f, %.2f°", y, a))
video { width = 32, height = 32, fps = 10, duration = 1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	testing.expect_value(t, len(s.load_problems), 0)
}

// physics3d{}, physics3d_at (and physics_at dispatch), physics3d_instances,
// primitive/compound/model colliders, 3D joints, kicks, shared{} cloning and
// self-checks (overlap, offscreen, unsettled and unused fields).
@(test)
test_physics3d_api :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_physics3d_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	obj_path, _ := filepath.join({dir, "crate.obj"}, context.temp_allocator)
	obj := `
v -0.5 -0.5 -0.5
v  0.5 -0.5 -0.5
v  0.5  0.5 -0.5
v -0.5  0.5 -0.5
v -0.5 -0.5  0.5
v  0.5 -0.5  0.5
v  0.5  0.5  0.5
v -0.5  0.5  0.5
f 1 2 3 4
f 5 8 7 6
f 1 5 6 2
f 2 6 7 3
f 3 7 8 4
f 4 8 5 1
`
	testing.expect(t, os.write_entire_file(obj_path, transmute([]u8)obj) == nil)
	src := `
local sim = shared("sim3d", function()
  return physics3d {
    duration = 1.5,
    rate = 120,
    gravity = { 0, -9.81, 0 },
    bounds = { x = { -20, 20 }, y = { -5, 25 }, z = { -20, 20 } },
    bodies = {
      { name = "floor", box = { 30, 1, 30 }, position = { 0, -0.5, 0 }, static = true, friction = 0.8 },
      { name = "cube", box = 1, position = { 0, 2, 0 }, bounce = 0.1 },
      { name = "ball", sphere = 0.5, position = { 2, 2, 0 } },
      { name = "pill", capsule = { radius = 0.25, height = 1 }, position = { -2, 2, 0 } },
      { name = "drum", cylinder = { radius = 0.4, height = 0.8, segments = 12 }, position = { 4, 2, 0 } },
      { name = "tip", cone = { radius = 0.4, height = 0.8, segments = 12 }, position = { -4, 2, 0 } },
      { name = "frustum", cone = { radius = 0.4, radius_top = 0.2, height = 0.8, segments = 32 }, position = { 10, 2, 0 } },
      { name = "tetra", hull = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }, position = { 6, 2, 0 } },
      { name = "crate_dyn", hull = "crate.obj", scale = 0.8, position = { -6, 2, 0 } },
      { name = "crate_stat", mesh = "crate.obj", position = { -8, 0.5, 0 }, static = true },
      { name = "ramp", mesh = { vertices = { -1, 0, -1, 1, 0, -1, 1, 0, 1, -1, 0, 1 }, indices = { 1, 3, 2, 1, 4, 3 } }, position = { 8, 0, 0 }, static = true },
      { name = "compound", shapes = { { box = 0.4, position = { -0.3, 0, 0 } }, { sphere = 0.2, position = { 0.3, 0, 0 } } }, position = { 0, 4, 2 } },
      { name = "mover", box = 0.5, position = { 0, 6, 0 }, kinematic = true, move = function(t) return { t * 2, 6, 0 }, { 0, t, 0 } end },
      { name = "pend", sphere = 0.3, position = { 1, 8, 0 }, leaves = true },
    },
    joints = {
      { "hinge", b = "pend", at = { 0, 8, 0 }, axis = { 0, 0, 1 } },
      { "spring", a = "cube", b = "ball", hertz = 1, damping = 0.5 },
    },
    kicks = {
      { t = 0.1, body = "ball", velocity = { 0.5, 0, 0 }, spin = { 0, 0.2, 0 } },
    },
  }
end)

local p0, r0 = physics3d_at(sim, "cube", 0)
local p1, r1 = physics_at(sim, "cube", 1.2)
assert(math.abs(p0[2] - 2) < 1e-4 and p1[2] < 0.6 and p1[2] > 0.4, tostring(p1[2]))
-- cylinders and cones are about their centres: each rests on its base with its centre half its height up
for _, name in ipairs({ "drum", "tip", "frustum" }) do
  local p = physics3d_at(sim, name, 1.2)
  assert(math.abs(p[2] - 0.4) < 0.02, name .. " rests at " .. p[2])
end
local mp, mr = physics3d_at(sim, "mover", 0.5)
assert(math.abs(mp[1] - 1.0) < 1e-2 and math.abs(mr[2] - 0.5) < 1e-2)
local inst = physics3d_instances(sim, 1.0, { "cube", "ball", "crate_dyn" })
assert(#inst == 3 and #inst[1].position == 3 and #inst[1].rotation == 3)
local default_inst = physics3d_instances(sim, 1.0)
assert(#default_inst == 11, tostring(#default_inst))

-- Diagnostics check: overlap, offscreen, unsettled and unused option fields.
local bad = physics3d {
  duration = 0.5,
  gravty = -9.8,
  bounds = { y = { -2, 10 }, w = 1 },
  bodies = {
    { name = "a", box = 1, position = { 0, 2, 0 }, static = true, mas = 1 },
    { name = "b", box = 1, position = { 0, 2.2, 0 } },
    { name = "faller", sphere = 0.3, position = { 5, 0, 0 }, velocity = { 0, -20, 0 } },
  },
}

video { width = 32, height = 32, fps = 10, duration = 1 }
scene { "A", duration = 1, render = function(f)
  physics3d_at(bad, "faller", 1.0)
  view3d {
    meshes = {
      { geometry = { type = "BoxGeometry" }, instances = physics3d_instances(sim, f.seconds, { "cube", "crate_dyn" }) },
    },
  }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	testing.expect_value(t, om.media_load_dir(&media, dir), om.Error.None)

	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))

	bodies := physics_bodies(&s)
	testing.expect(t, len(bodies) >= 13)
	if len(bodies) >= 2 {
		testing.expect(t, bodies[1].is_3d)
		testing.expect_value(t, bodies[1].label, "cube")
		testing.expect(t, bodies[1].start.y > 1.9 && bodies[1].stop.y < 0.6)
	}

	// Second load reuses the shared 3D tracks without re-simulating `sim`.
	s2: Script
	defer unload(&s2)
	testing.expectf(t, load(&s2, path, nil, &media, &sh) == nil, "second load failed: %s", error_message(s2.failure, context.temp_allocator))

	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)

	testing.expect_value(t, len(s.load_problems), 5)
	has_overlap, has_offscreen, has_unsettled := false, false, false
	for d in s.load_problems {
		#partial switch d.code {
		case .Physics3d_Overlap:
			has_overlap = d.a == "b" && d.b == "a"
		case .Physics3d_Offscreen:
			has_offscreen = d.a == "faller"
		}
	}
	for d in r.ctx.diagnostics {
		if d.code == .Physics_Unsettled && d.a == "faller" {
			has_unsettled = true
		}
	}
	testing.expect(t, has_overlap)
	testing.expect(t, has_offscreen)
	testing.expect(t, has_unsettled)
}


// physics3d's Euler XYZ <-> quaternion conversions turn bodies the way
// view3d does (o3d.compose), and an angle comes back as it went in.
@(test)
test_physics3d_euler :: proc(t: ^testing.T) {
	rots := [?]o3d.Vec3{{0.3, 0.5, 0}, {-1.2, 0.4, 2.5}, {0, 0, 0}, {2.9, -1.1, 0.2}}
	for r in rots {
		q := euler_xyz_to_quat(r)
		want := o3d.compose({}, r)
		got := linalg.matrix4_from_quaternion(q)
		for col in 0 ..< 3 {
			for row in 0 ..< 3 {
				testing.expectf(t, abs(got[col][row] - want[col][row]) < 1e-5, "rotation %v: [%d][%d] is %v, view3d has %v", r, col, row, got[col][row], want[col][row])
			}
		}
		back := o3d.compose({}, quat_to_euler_xyz(q))
		for col in 0 ..< 3 {
			for row in 0 ..< 3 {
				testing.expectf(t, abs(back[col][row] - want[col][row]) < 1e-5, "rotation %v does not come back", r)
			}
		}
	}
}

@(test)
test_new_3d_audio_bloom_features :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_new_features_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `

audio_add("tone.wav", function()
  local samples = {}
  for i = 1, 22050 do
    samples[i] = math.sin(2 * math.pi * 110 * (i - 1) / 44100) * 0.7
  end
  return { samples, samples, rate = 44100 }
end)

video {
  width = 64, height = 64, fps = 10, duration = 0.5, background = "#000000",
  audio = { { "tone.wav", start = 0 } },
}

scene { "A", duration = 0.5, render = function(f)
  local e = audio_energy(f)
  local low = audio_energy(f, { src = "tone.wav", smooth = 1 }).low
  assert(e.rms > 0.05 and e.peak > 0.1 and low >= 0)

  group({ bloom = { threshold = 0.5, intensity = 0.8, radius = 4 } }, function()
    rect { x = 8, y = 8, w = 16, h = 16, fill = "#ffffff" }
  end)

  view3d {
    bloom = 4,
    lights = {
      { type = "AmbientLight", intensity = 0.8 },
      { type = "DirectionalLight", position = { 2, 4, 5 }, intensity = 1.2 },
    },
    meshes = {
      {
        geometry = { type = "CapsuleGeometry", radius = 0.25, height = 0.8, cap_segments = 6, radial_segments = 12 },
        from = { -1, -0.5, 0 },
        to = { 1, 0.5, 0 },
        stretch = true,
        material = {
          type = "ShaderMaterial",
          vertex_shader = "varying vec3 vCol; void main() { vCol = instanceColor + vec3(instanceId * 0.1); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
          fragment_shader = "varying vec3 vCol; void main() { gl_FragColor = vec4(vCol, 1.0); }",
        },
        instances = {
          { from = { -0.8, -0.4, 0 }, to = { 0.8, 0.4, 0 }, color = "#00ff88" },
          { position = { 0, 0, 0 }, look_at = { 0, 0, 5 }, color = "#ff0055" },
        },
      },
      {
        geometry = {
          type = "TubeGeometry",
          radius = 0.12,
          radial_segments = 10,
          points = { { -1, 0, 0 }, { 0, 0.5, 0 }, { 1, 0, 0 } },
        },
        material = { type = "MeshStandardMaterial", color = "#38bdf8" },
      },
    },
  }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 1)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "unexpected diagnostics: %v", r.ctx.diagnostics[:])
}


// view3d's blending, per-point colours and lens flares read into the node:
// an additive material, points with a colour each (a count that differs is
// an error), a flare's elements as flare panels; a misspelled flare key
// is an unused field.
@(test)
test_view3d_blending_colors_flares :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_flares_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
video { width = 64, height = 48, fps = 10, duration = 0.1, background = "#000000", render = function(f)
  view3d { camera = { position = { 0, 0, 5 } },
    meshes = {
      { geometry = { type = "SphereGeometry" }, material = { type = "MeshBasicMaterial", color = "#204080", blending = "additive" } },
      { geometry = { type = "PointsGeometry", points = { { -1, 0, 0 }, { 1, 0, 0 } }, colors = { "#ff0000", rgba(0, 255, 0, 0.5) } },
        material = { size = 0.2 } },
    },
    lensflares = { { position = { 1.5, 1, 0 }, occlusion_radus = 4, elements = {
      { size = 12, distance = 0, draw = function() rect { x = 0, y = 0, w = 12, h = 12, fill = "#fff" } end },
      { size = 6, distance = 0.6, draw = function() rect { x = 0, y = 0, w = 6, h = 6, fill = "#88f" } end },
    } } },
  }
  assert(not pcall(view3d, { meshes = { { geometry = { type = "PointsGeometry", points = { { 0, 0, 0 } }, colors = { "#fff", "#000" } } } } }))
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)
	unused := 0
	for d in r.ctx.diagnostics {
		testing.expectf(t, d.code == .Unused_Field, "diagnostic: %v", d)
		unused += 1 if d.code == .Unused_Field else 0
	}
	testing.expect_value(t, unused, 1)
	found := false
	for n in r.ctx.tree.nodes {
		v, ok := n.kind.(om.View3d)
		if !ok || len(v.meshes) != 2 {
			continue
		}
		found = true
		testing.expect(t, .Additive in v.meshes[0].material.flags)
		testing.expect_value(t, len(v.meshes[1].colors), 2)
		if len(v.meshes[1].colors) == 2 {
			testing.expect_value(t, v.meshes[1].colors[1], o3d.Vec4{0, 1, 0, 0.5})
		}
		testing.expect_value(t, len(v.labels), 2)
		if len(v.labels) == 2 {
			testing.expect(t, v.labels[0].flare && v.labels[1].flare)
			testing.expect_value(t, v.labels[1].distance, 0.6)
			testing.expect_value(t, v.labels[1].w, 6)
			testing.expect_value(t, v.labels[0].occlusion_radius, 8) // the misspelled key leaves the default
		}
	}
	testing.expect(t, found)
}

// thrusts push a body by its mass times an acceleration, held over a window,
// in its own frame: 2 m/s² for a second moves a body 1 m in that second and
// 2 m a second after; off its centre the same push turns it as well. In 2D
// the same in pixels.
@(test)
test_physics_thrusts :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_thrusts_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local sim = physics3d { duration = 3, gravity = 0, bounds = false,
  bodies = { { name = "centred", box = 1, density = 2 }, { name = "off", box = 1, position = { 5, 0, 0 } } },
  thrusts = {
    { from = 0, to = 1, body = "centred", acceleration = { 0, 0, 2 } },
    { from = 0, to = 1, body = "off", acceleration = { 0, 0, 2 }, at = { 0.5, 0, 0 } },
  } }
local function near(a, b, eps, what) assert(math.abs(a - b) < eps, what .. ": " .. a .. " ~= " .. b) end
local p1 = physics3d_at(sim, "centred", 1)
local p2, r2 = physics3d_at(sim, "centred", 2)
near(p1[3], 1, 0.03, "a second of 2 m/s²")
near(p2[3], 3, 0.05, "then 2 m/s")
near(p2[1], 0, 1e-4, "straight") near(r2[2], 0, 1e-4, "no turn")
local _, ro = physics3d_at(sim, "off", 2)
assert(math.abs(ro[2]) > 0.1, "off its centre it turns: " .. ro[2])

-- turned a quarter about y: along its own z is the world's x; world_space keeps the world's z
local turned = physics3d { duration = 2, gravity = 0, bounds = false,
  bodies = { { name = "own", box = 1, rotation = { 0, math.pi / 2, 0 } },
    { name = "world", box = 1, position = { 0, 5, 0 }, rotation = { 0, math.pi / 2, 0 } } },
  thrusts = { { from = 0, to = 1, body = "own", acceleration = { 0, 0, 2 } },
    { from = 0, to = 1, body = "world", acceleration = { 0, 0, 2 }, world_space = true } } }
local po = physics3d_at(turned, "own", 1)
local pw = physics3d_at(turned, "world", 1)
near(po[1], 1, 0.03, "its own z is the world's x") near(po[3], 0, 1e-3, "not the world's z")
near(pw[3], 1, 0.03, "world_space: the world's z") near(pw[1], 0, 1e-3, "not its own z")

local flat = physics { duration = 3, gravity = 0,
  bodies = { { name = "tile", box = { 40, 40 }, x = 100, y = 100, leaves = true } },
  thrusts = { { from = 0, to = 1, body = "tile", ax = 0, ay = 200 } } }
local _, y1 = physics_at(flat, "tile", 1)
local _, y2 = physics_at(flat, "tile", 2)
near(y1, 200, 3, "a second of 200 px/s²") near(y2, 400, 5, "then 200 px/s")
local tilted = physics { duration = 2, gravity = 0,
  bodies = { { name = "own", box = { 40, 40 }, x = 100, y = 100, angle = 90, leaves = true },
    { name = "world", box = { 40, 40 }, x = 300, y = 100, angle = 90, leaves = true } },
  thrusts = { { from = 0, to = 1, body = "own", ax = 0, ay = 200 },
    { from = 0, to = 1, body = "world", ax = 0, ay = 200, world_space = true } } }
local ox, oy = physics_at(tilted, "own", 1)
local wx, wy = physics_at(tilted, "world", 1)
near(ox, 0, 3, "turned 90°, its own y is across the canvas") near(oy, 100, 3, "not down it")
near(wy, 200, 3, "world_space: down the canvas") near(wx, 300, 3, "not across")
video { width = 32, height = 32, fps = 10, duration = 0.1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
}

// attach = { sim, body } rides a physics3d body (meshes and emitters alike);
// an emitter's start, stop and bursts read into it; world_space without a
// body is an error.
@(test)
test_view3d_attach_body :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_attach_body_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local sim = physics3d { duration = 2, gravity = 0, bodies = { { name = "ship", box = 1, velocity = { 1, 0, 0 } } } }
video { width = 32, height = 32, fps = 10, duration = 0.1, render = function(f)
  view3d { camera = { position = { 0, 0, 10 } },
    meshes = { { geometry = { type = "BoxGeometry" }, attach = { sim = sim, body = "ship" } } },
    particles = { { rate = 0, bursts = { { t = 0, count = 4 } }, start = 0.2, stop = 0.5, world_space = true,
      attach = { sim = sim, body = 1 } } } }
  assert(not pcall(view3d, { particles = { { rate = 5, world_space = true } } }))
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
	found := false
	for n in r.ctx.tree.nodes {
		v, ok := n.kind.(om.View3d)
		if !ok || len(v.particles) != 1 {
			continue
		}
		found = true
		testing.expect(t, v.meshes[0].attach.track.sample != nil)
		e := v.particles[0]
		testing.expect(t, e.world_space && e.attach.track.sample != nil)
		testing.expect_value(t, e.start, 0.2)
		testing.expect_value(t, e.stop, 0.5)
		testing.expect_value(t, len(e.bursts), 1)
		if len(e.bursts) == 1 {
			testing.expect_value(t, e.bursts[0].count, 4)
		}
	}
	testing.expect(t, found)
}

// model_info's parts: each named node's own pose, what `nodes` replaces
// (Body: 2 up, a quarter turn about z), and the rest box of it and what is
// under it in the model's space (Tip, 1 along Body's x, is 1 up: its
// triangle spans y 2.5..3.5). sky{} bakes an image by name at load, once
// for the same sky, which environment and background take.
@(test)
test_model_parts_and_sky :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_parts_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	Bin :: struct #packed {
		pos: [3][3]f32,
		idx: [3]u16,
		_:   u16,
	}
	b := Bin{pos = {{-0.5, -0.5, 0}, {0.5, -0.5, 0}, {0, 0.5, 0}}, idx = {0, 1, 2}}
	data, _ := base64.encode(([^]u8)(&b)[:size_of(Bin)], allocator = context.temp_allocator)
	gltf := fmt.tprintf(`{{
  "asset": {{"version": "2.0"}},
  "buffers": [{{"uri": "data:application/octet-stream;base64,%s", "byteLength": 44}}],
  "bufferViews": [{{"buffer": 0, "byteOffset": 0, "byteLength": 36}}, {{"buffer": 0, "byteOffset": 36, "byteLength": 6}}],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [-0.5, -0.5, 0], "max": [0.5, 0.5, 0]}},
    {{"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}}
  ],
  "meshes": [{{"primitives": [{{"attributes": {{"POSITION": 0}}, "indices": 1}}]}}],
  "nodes": [
    {{"name": "Body", "translation": [0, 2, 0], "rotation": [0, 0, 0.70710678, 0.70710678], "children": [1]}},
    {{"name": "Tip", "mesh": 0, "translation": [1, 0, 0]}}
  ],
  "scenes": [{{"nodes": [0]}}],
  "scene": 0
}}`, data)
	model_path, _ := filepath.join({dir, "tri.gltf"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(model_path, transmute([]u8)gltf) == nil)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local function near(a, b) return math.abs(a - b) < 1e-4 end
local info = model_info("tri.gltf")
local body, tip = info.parts.Body, info.parts.Tip
assert(near(body.position[2], 2) and near(body.rotation[3], math.pi / 2) and near(body.scale[1], 1))
assert(near(body.min[1], -0.5) and near(body.max[1], 0.5) and near(body.min[2], 2.5) and near(body.max[2], 3.5))
assert(near(tip.position[1], 1) and near(tip.rotation[3], 0) and near(tip.min[2], 2.5) and near(tip.center[2], 3))
local dawn = sky { name = "dawn", sun = { 1, 0.1, 0 }, turbidity = 10, size = 64 }
assert(dawn == "dawn" and sky { name = "dawn", sun = { 1, 0.1, 0 }, turbidity = 10, size = 64 } == "dawn")
video { width = 32, height = 32, fps = 10, duration = 0.1, render = function(f)
  view3d { camera = { position = { 0, 0, 5 } }, environment = dawn, background = dawn,
    models = { { src = "tri.gltf" } } }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	testing.expect_value(t, om.media_load_dir(&media, dir), om.Error.None)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	testing.expect_value(t, len(media.view3d.skies), 1)
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
}

// Each of several groups keeps what it holds, whatever the groups before it
// held (a first group without meshes once had the next one start the
// lists over, losing its models and particles), and an emitter left behind
// (world_space) may ride its group's body.
@(test)
test_view3d_groups_items :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_groups_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local sim = physics3d { duration = 2, gravity = 0, bodies = { { name = "ship", box = 1 } } }
video { width = 32, height = 32, fps = 10, duration = 0.1, render = function(f)
  view3d { camera = { position = { 0, 0, 10 } },
    groups = {
      { position = { 1, 0, 0 }, particles = { { rate = 0, bursts = { { t = 0, count = 2 } } } } },
      { position = { 2, 0, 0 }, attach = { sim = sim, body = "ship" },
        particles = { { rate = 0, bursts = { { t = 0, count = 2 } }, world_space = true } } },
      { position = { 3, 0, 0 }, meshes = { { geometry = { type = "BoxGeometry" } } } },
    } }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)
	testing.expectf(t, len(r.ctx.diagnostics) == 0, "diagnostics: %v", r.ctx.diagnostics[:])
	found := false
	for n in r.ctx.tree.nodes {
		v, ok := n.kind.(om.View3d)
		if !ok {
			continue
		}
		found = true
		testing.expect_value(t, len(v.particles), 2)
		testing.expect_value(t, len(v.meshes), 1)
		if len(v.particles) == 2 && len(v.meshes) == 1 {
			testing.expect_value(t, om.group_transform(v.particles[0].group)[3].x, 1)
			testing.expect_value(t, om.group_transform(v.particles[1].group)[3].x, 2)
			testing.expect_value(t, om.group_transform(v.meshes[0].group)[3].x, 3)
			testing.expect(t, v.particles[1].world_space && v.particles[1].attach.track.sample != nil)
		}
	}
	testing.expect(t, found)
}

// view3d_project's depth runs 0 at the near plane to 1 at the far one
// (o3d's own is reversed): nearer points have less, and a point 10 units out
// with near 1, far 100 is at far (z - near) / (z (far - near)).
@(test)
test_view3d_project_depth :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_project_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
local cam = { position = { 0, 0, 0 }, target = { 0, 0, -1 }, near = 1, far = 100 }
local a = view3d_project(cam, { 0, 0, -10 }, { width = 100, height = 100 })
local b = view3d_project(cam, { 0, 0, -50 }, { width = 100, height = 100 })
assert(a.in_front and b.in_front and a.depth < b.depth, a.depth .. " " .. b.depth)
local want = 100 * (10 - 1) / (10 * (100 - 1))
assert(math.abs(a.depth - want) < 1e-4, a.depth .. " ~= " .. want)
assert(math.abs(a.x - 50) < 1e-3 and math.abs(a.y - 50) < 1e-3)
video { width = 32, height = 32, fps = 10, duration = 0.1 }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
}

// A material's projection: its maps by the mesh's uvs (the default) or
// projected along three axes in the mesh's own space or the world's, with
// the repeats per unit and the blend's sharpness; another name is
// invalid_value, naming the ones there are.
@(test)
test_view3d_projection :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "onimite_projection_test_*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "video.lua"}, context.temp_allocator)
	src := `
video { width = 32, height = 32, fps = 10, duration = 0.1, render = function(f)
  view3d { camera = { position = { 0, 0, 5 } }, meshes = {
    { geometry = { type = "BoxGeometry" }, material = { projection = "object", projection_scale = 0.5, projection_sharpness = 6 } },
    { geometry = { type = "BoxGeometry" }, material = { type = "MeshBasicMaterial", projection = "world" } },
    { geometry = { type = "BoxGeometry" } },
  } }
  view3d { meshes = { { geometry = { type = "BoxGeometry" }, material = { projection = "cubic" } } } }
end }
`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)src) == nil)
	media: om.Media
	om.media_init(&media)
	defer om.media_destroy(&media)
	sh: Shared
	defer shared_destroy(&sh)
	s: Script
	defer unload(&s)
	testing.expectf(t, load(&s, path, nil, &media, &sh) == nil, "load failed: %s", error_message(s.failure, context.temp_allocator))
	r: om.Renderer
	testing.expect_value(t, om.renderer_init(&r, &s.video, &media), om.Error.None)
	defer om.renderer_destroy(&r)
	om.render_frame(&r, 0)
	testing.expect_value(t, len(r.ctx.diagnostics), 1)
	if len(r.ctx.diagnostics) == 1 {
		d := r.ctx.diagnostics[0]
		testing.expect(t, d.code == .Invalid_Value && d.name == "material projection" && d.a == "cubic")
	}
	found := false
	for n in r.ctx.tree.nodes {
		v, ok := n.kind.(om.View3d)
		if !ok || len(v.meshes) != 3 {
			continue
		}
		found = true
		testing.expect_value(t, v.meshes[0].material.projection, o3d.Map_Projection.Object)
		testing.expect_value(t, v.meshes[0].material.projection_scale, 0.5)
		testing.expect_value(t, v.meshes[0].material.projection_sharpness, 6)
		testing.expect_value(t, v.meshes[1].material.projection, o3d.Map_Projection.World)
		testing.expect_value(t, v.meshes[2].material.projection, o3d.Map_Projection.Uv)
	}
	testing.expect(t, found)
}
