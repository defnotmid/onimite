package onimite_script

import "core:c"
import "core:math"
import om "../onimite"
import lua "vendor:lua/5.4"

// audio_buffer(seconds): stereo samples at 48 kHz kept natively (4 bytes a
// sample, not a Lua value each), for music a script synthesizes. Lua
// computes one sound at a time into a short list and adds it:
//
//     local mix = audio_buffer(30)
//     mix:add(t0, samples, pan, n)        -- a mono list (n values, default #samples) at t0 seconds
//     mix:add_stereo(t0, left, right, n)  -- two lists
//     mix:lowpass(11000)                  -- one-pole low-pass, Hz (or a function of seconds, per 128 samples)
//     mix:normalize(0.89)                 -- scales the peak to 0.89 (about -1 dBFS)
//     mix:gain(0.5)                       -- scales everything
//     audio_add("track", mix)
//
// Pan follows the examples' synth: left gets v * (1 - pan), right v * (1 + pan).

@(private)
AUDIO_BUFFER :: "onimite.audio_buffer"

// The userdata: its frame count, then interleaved stereo samples.
@(private)
Audio_Buffer :: struct {
	frames: int,
}

@(private)
buffer_samples :: proc "contextless" (b: ^Audio_Buffer) -> []f32 {
	return ([^]f32)(rawptr(uintptr(b) + size_of(Audio_Buffer)))[:b.frames * 2]
}

@(private)
check_buffer :: proc "contextless" (L: ^lua.State, idx: c.int) -> ^Audio_Buffer {
	return (^Audio_Buffer)(lua.L_checkudata(L, idx, AUDIO_BUFFER))
}

// The buffer at `idx`, or nil when it is something else.
@(private)
test_buffer :: proc "contextless" (L: ^lua.State, idx: c.int) -> ^Audio_Buffer {
	return (^Audio_Buffer)(lua.L_testudata(L, idx, AUDIO_BUFFER))
}

// The buffers' methods (the global `audio_buffer` makes one).
@(private)
register_audio_buffer_methods :: proc(s: ^Script) {
	L := s.L
	lua.L_newmetatable(L, AUDIO_BUFFER)
	methods := [?]lua.L_Reg {
		{"add", l_buffer_add},
		{"add_stereo", l_buffer_add_stereo},
		{"lowpass", l_buffer_lowpass},
		{"normalize", l_buffer_normalize},
		{"gain", l_buffer_gain},
		{"seconds", l_buffer_seconds},
		{nil, nil},
	}
	lua.createtable(L, 0, len(methods))
	lua.L_setfuncs(L, raw_data(methods[:]), 0)
	lua.setfield(L, -2, "__index")
	lua.pop(L, 1)
}

@(private)
l_audio_buffer :: proc "c" (L: ^lua.State) -> c.int {
	seconds := f64(lua.L_checknumber(L, 1))
	if seconds < 0 || seconds > 6 * 3600 {
		lua.L_error(L, "audio_buffer(seconds): 0 to 6 hours")
	}
	frames := int(seconds * om.MIX_RATE)
	b := (^Audio_Buffer)(lua.newuserdatauv(L, c.size_t(size_of(Audio_Buffer) + frames * 8), 0))
	b.frames = frames
	samples := ([^]f32)(rawptr(uintptr(b) + size_of(Audio_Buffer)))[:frames * 2]
	for &v in samples {
		v = 0
	}
	lua.L_setmetatable(L, AUDIO_BUFFER)
	return 1
}

// mix:add(t0, samples, pan = 0, n = #samples)
@(private = "file")
l_buffer_add :: proc "c" (L: ^lua.State) -> c.int {
	b := check_buffer(L, 1)
	t0 := f64(lua.L_checknumber(L, 2))
	lua.L_checktype(L, 3, i32(lua.Type.TABLE))
	pan := f32(lua.L_optnumber(L, 4, 0))
	n := int(lua.L_optinteger(L, 5, lua.Integer(lua.rawlen(L, 3))))
	out := buffer_samples(b)
	first := int(math.floor(t0 * om.MIX_RATE))
	gl, gr := 1 - pan, 1 + pan
	for k in max(0, -first) ..< n {
		i := first + k
		if i >= b.frames {
			break
		}
		lua.rawgeti(L, 3, lua.Integer(k + 1))
		v := f32(lua.tonumber(L, -1))
		lua.pop(L, 1)
		out[i * 2] += v * gl
		out[i * 2 + 1] += v * gr
	}
	return 0
}

// mix:add_stereo(t0, left, right, n = #left)
@(private = "file")
l_buffer_add_stereo :: proc "c" (L: ^lua.State) -> c.int {
	b := check_buffer(L, 1)
	t0 := f64(lua.L_checknumber(L, 2))
	lua.L_checktype(L, 3, i32(lua.Type.TABLE))
	lua.L_checktype(L, 4, i32(lua.Type.TABLE))
	n := int(lua.L_optinteger(L, 5, lua.Integer(lua.rawlen(L, 3))))
	out := buffer_samples(b)
	first := int(math.floor(t0 * om.MIX_RATE))
	for k in max(0, -first) ..< n {
		i := first + k
		if i >= b.frames {
			break
		}
		lua.rawgeti(L, 3, lua.Integer(k + 1))
		lua.rawgeti(L, 4, lua.Integer(k + 1))
		out[i * 2] += f32(lua.tonumber(L, -2))
		out[i * 2 + 1] += f32(lua.tonumber(L, -1))
		lua.pop(L, 2)
	}
	return 0
}

// mix:lowpass(hz) or mix:lowpass(function(seconds) return hz end): a
// one-pole low-pass over the whole buffer; a function is asked every 128
// samples (automation: a filter closing for a hush).
@(private = "file")
l_buffer_lowpass :: proc "c" (L: ^lua.State) -> c.int {
	b := check_buffer(L, 1)
	automated := lua.isfunction(L, 2)
	hz := f64(0) if automated else f64(lua.L_checknumber(L, 2))
	out := buffer_samples(b)
	yl, yr: f32
	BLOCK :: 128
	for first := 0; first < b.frames; first += BLOCK {
		if automated {
			lua.pushvalue(L, 2)
			lua.pushnumber(L, lua.Number(f64(first) / om.MIX_RATE))
			lua.call(L, 1, 1)
			hz = f64(lua.tonumber(L, -1))
			lua.pop(L, 1)
		}
		k := f32(1 - math.exp(-2 * math.PI * hz / om.MIX_RATE))
		for i in first ..< min(first + BLOCK, b.frames) {
			yl += k * (out[i * 2] - yl)
			yr += k * (out[i * 2 + 1] - yr)
			out[i * 2], out[i * 2 + 1] = yl, yr
		}
	}
	return 0
}

// mix:normalize(peak = 0.89) -> the gain applied (1 for silence)
@(private = "file")
l_buffer_normalize :: proc "c" (L: ^lua.State) -> c.int {
	b := check_buffer(L, 1)
	target := f32(lua.L_optnumber(L, 2, 0.89))
	out := buffer_samples(b)
	top: f32
	for v in out {
		top = max(top, abs(v))
	}
	g: f32 = 1
	if top > 0 {
		g = target / top
		for &v in out {
			v *= g
		}
	}
	lua.pushnumber(L, lua.Number(g))
	return 1
}

// mix:gain(g): every sample times g (a level set once for clips that are
// mixed together, where normalizing each would change their balance)
@(private = "file")
l_buffer_gain :: proc "c" (L: ^lua.State) -> c.int {
	b := check_buffer(L, 1)
	g := f32(lua.L_checknumber(L, 2))
	for &v in buffer_samples(b) {
		v *= g
	}
	return 0
}

// mix:seconds() -> its length
@(private = "file")
l_buffer_seconds :: proc "c" (L: ^lua.State) -> c.int {
	b := check_buffer(L, 1)
	lua.pushnumber(L, lua.Number(f64(b.frames) / om.MIX_RATE))
	return 1
}
