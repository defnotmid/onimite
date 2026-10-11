package platform

import "core:c"
import "core:strings"
import sdl "vendor:sdl3"

// Native key set — only the keys this app uses. Mapped to SDL scancodes below.
Key :: enum u8 {
	None,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, V, W, X, Z,
	Zero, One, Two, Three, Four, Five, Six, Seven, Eight, Nine,
	Minus, Equals, Left_Bracket, Right_Bracket,
	Space, Enter, Escape, Backspace, Delete, Tab, Home, End, Page_Up, Page_Down,
	Left, Right, Up, Down,
	LShift, RShift, LCtrl, RCtrl,
}

Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
}

Input :: struct {
	key_down:      [Key]bool, // level state, from events
	key_hit:       [Key]bool, // a KEY_DOWN that was not a repeat arrived this frame
	key_repeat:    [Key]bool, // a held key auto-repeated this frame
	mb_down:       [Mouse_Button]bool,
	mb_prev:       [Mouse_Button]bool,
	mouse:         [2]f32, // pixels
	mouse_prev:    [2]f32,
	mouse_delta:   [2]f32,
	wheel:         f32, // vertical wheel ticks this frame
	wheel_x:       f32, // horizontal wheel / touchpad ticks this frame (right is positive)
	text:          [dynamic]u8, // UTF-8 text typed this frame (line edits)
	dropped_files: [dynamic]string,
	primed:        bool, // first tick has established button state
	user_seen:     bool, // a real motion, button, or key event has arrived
}

key_scancodes := [Key]sdl.Scancode {
	.None = .UNKNOWN,
	.A = .A, .B = .B, .C = .C, .D = .D, .E = .E, .F = .F, .G = .G, .H = .H, .I = .I,
	.J = .J, .K = .K, .L = .L, .M = .M, .N = .N, .O = .O, .P = .P, .Q = .Q, .R = .R, .S = .S,
	.T = .T, .V = .V, .W = .W, .X = .X, .Z = .Z,
	.Zero = ._0, .One = ._1, .Two = ._2, .Three = ._3, .Four = ._4, .Five = ._5,
	.Six = ._6, .Seven = ._7, .Eight = ._8, .Nine = ._9,
	.Minus = .MINUS, .Equals = .EQUALS, .Left_Bracket = .LEFTBRACKET, .Right_Bracket = .RIGHTBRACKET,
	.Space = .SPACE, .Enter = .RETURN, .Escape = .ESCAPE,
	.Backspace = .BACKSPACE, .Delete = .DELETE, .Tab = .TAB, .Home = .HOME, .End = .END,
	.Page_Up = .PAGEUP, .Page_Down = .PAGEDOWN,
	.Left = .LEFT, .Right = .RIGHT, .Up = .UP, .Down = .DOWN,
	.LShift = .LSHIFT, .RShift = .RSHIFT, .LCtrl = .LCTRL, .RCtrl = .RCTRL,
}

// ---- per-frame queries ----
// Edges are the events themselves, not a diff of level state between ticks:
// a press and release that land in the same pump (a fast tap, or a
// compositor repeat delivered as down/up pairs) would otherwise vanish.
key_down     :: proc(p: ^Platform, k: Key) -> bool { return p.input.key_down[k] }
key_pressed  :: proc(p: ^Platform, k: Key) -> bool { return p.input.key_hit[k] }
// key_typed is a press or an auto-repeat: what editing and navigation keys
// want, so holding Backspace keeps deleting.
key_typed    :: proc(p: ^Platform, k: Key) -> bool { return key_pressed(p, k) || p.input.key_repeat[k] }

mouse_down     :: proc(p: ^Platform, b: Mouse_Button) -> bool { return p.input.mb_down[b] }
mouse_pressed  :: proc(p: ^Platform, b: Mouse_Button) -> bool { return p.input.mb_down[b] && !p.input.mb_prev[b] }
mouse_released :: proc(p: ^Platform, b: Mouse_Button) -> bool { return !p.input.mb_down[b] && p.input.mb_prev[b] }

mouse_pos   :: proc(p: ^Platform) -> [2]f32 { return p.input.mouse }
mouse_delta :: proc(p: ^Platform) -> [2]f32 { return p.input.mouse_delta }
mouse_wheel :: proc(p: ^Platform) -> f32    { return p.input.wheel }
mouse_wheel_x :: proc(p: ^Platform) -> f32  { return p.input.wheel_x }
dropped_files :: proc(p: ^Platform) -> []string { return p.input.dropped_files[:] }

// Modifiers come from SDL's modifier state, which the compositor supplies
// whenever keyboard focus enters the window, so a shift already held when
// the pointer arrives still counts.
shift_down :: proc(p: ^Platform) -> bool {
	mods := sdl.GetModState()
	return .LSHIFT in mods || .RSHIFT in mods || p.input.key_down[.LShift] || p.input.key_down[.RShift]
}
ctrl_down :: proc(p: ^Platform) -> bool {
	mods := sdl.GetModState()
	return .LCTRL in mods || .RCTRL in mods || p.input.key_down[.LCtrl] || p.input.key_down[.RCtrl]
}
input_dropped_files_clear :: proc(inp: ^Input) {
	for path in inp.dropped_files {
		delete(path)
	}
	clear(&inp.dropped_files)
}

input_button_set :: proc(inp: ^Input, button: u8, down: bool) {
	switch button {
	case sdl.BUTTON_LEFT:
		inp.mb_down[.Left] = down
	case sdl.BUTTON_MIDDLE:
		inp.mb_down[.Middle] = down
	case sdl.BUTTON_RIGHT:
		inp.mb_down[.Right] = down
	}
}

input_key_repeat :: proc(inp: ^Input, scancode: sdl.Scancode) {
	for k in Key {
		if key_scancodes[k] == scancode && scancode != .UNKNOWN {
			inp.key_repeat[k] = true
		}
	}
}

input_key_edge :: proc(inp: ^Input, scancode: sdl.Scancode, edges: ^[Key]bool) {
	for k in Key {
		if key_scancodes[k] == scancode && scancode != .UNKNOWN {
			edges[k] = true
		}
	}
}

input_key_is_down :: proc(inp: ^Input, scancode: sdl.Scancode) -> bool {
	for k in Key {
		if key_scancodes[k] == scancode && scancode != .UNKNOWN {
			return inp.key_down[k]
		}
	}
	return false
}

input_key_set :: proc(inp: ^Input, scancode: sdl.Scancode, down: bool) {
	for k in Key {
		if key_scancodes[k] == scancode && scancode != .UNKNOWN {
			inp.key_down[k] = down
		}
	}
}

_pump :: proc(p: ^Platform) {
	inp := &p.input
	inp.key_hit = {}
	inp.key_repeat = {}
	inp.mb_prev = inp.mb_down
	inp.mouse_prev = inp.mouse
	inp.wheel = 0
	inp.wheel_x = 0
	clear(&inp.text)
	input_dropped_files_clear(inp)
	p.resized = false

	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		#partial switch ev.type {
		case .QUIT:
			p.should_close = true
		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED:
			_update_size(p)
			p.resized = true
		case .MOUSE_WHEEL:
			inp.wheel += ev.wheel.y
			inp.wheel_x += ev.wheel.x
		case .KEY_DOWN:
			inp.user_seen = true
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: key %v down repeat=%v (t=%.2f)", ev.key.scancode, ev.key.repeat, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
			// A repeat is flagged by SDL, or arrives as a second KEY_DOWN for
			// a key still down (SDL3 on Wayland sends compositor repeats that
			// way, with the flag clear); both count as typed again.
			if ev.key.repeat || input_key_is_down(inp, ev.key.scancode) {
				input_key_repeat(inp, ev.key.scancode)
			} else {
				input_key_edge(inp, ev.key.scancode, &inp.key_hit)
			}
			input_key_set(inp, ev.key.scancode, true)
		case .KEY_UP:
			input_key_set(inp, ev.key.scancode, false)
		case .MOUSE_MOTION:
			inp.user_seen = true
		case .MOUSE_BUTTON_DOWN:
			inp.user_seen = true
			input_button_set(inp, ev.button.button, true)
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: button %d down at %.0f,%.0f (t=%.2f)", ev.button.button, ev.button.x, ev.button.y, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
		case .MOUSE_BUTTON_UP:
			input_button_set(inp, ev.button.button, false)
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: button %d up at %.0f,%.0f (t=%.2f)", ev.button.button, ev.button.x, ev.button.y, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
		case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST, .WINDOW_MOUSE_ENTER, .WINDOW_MOUSE_LEAVE:
			// Buttons and keys held across a focus or pointer boundary are
			// released here: the compositor will not tell us later.
			if ev.type == .WINDOW_FOCUS_LOST || ev.type == .WINDOW_MOUSE_LEAVE {
				inp.mb_down = {}
			}
			if ev.type == .WINDOW_FOCUS_LOST {
				inp.key_down = {}
			}
			if ev.type == .WINDOW_FOCUS_GAINED {
				// Keys already held when focus arrives never send KEY_DOWN;
				// seed them from the level state once, as state, not edges.
				nkeys: c.int
				ks := sdl.GetKeyboardState(&nkeys)
				for k in Key {
					sc := key_scancodes[k]
					inp.key_down[k] = sc != .UNKNOWN && int(sc) < int(nkeys) && ks[int(sc)]
				}
			}
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: window event %v (t=%.2f)", ev.type, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
		case .TEXT_INPUT:
			if ev.text.text != nil {
				append(&inp.text, ..transmute([]u8)string(ev.text.text))
			}
		case .DROP_FILE:
			if ev.drop.data != nil {
				append(&inp.dropped_files, strings.clone(string(ev.drop.data)))
			}
		}
	}

	// Key and button state comes from the events above, never from SDL's
	// polled level state: on Wayland the polled mask can report a button as
	// held for a moment when the pointer is warped into a freshly focused
	// window, which read as a click on whatever sat under it.

	// Mouse position: SDL reports logical points; convert to framebuffer pixels.
	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)
	inp.mouse = {mx * p.dpi_scale, my * p.dpi_scale}
	inp.mouse_delta = inp.mouse - inp.mouse_prev
	// A button already held when the window appears is state, not an edge:
	// without this the first tick reports a press wherever the cursor sits
	// and the matching release becomes a click on that widget.
	if !inp.primed {
		inp.mb_prev = inp.mb_down
		inp.key_hit = {}
		inp.mouse_prev = inp.mouse
		inp.mouse_delta = {}
		inp.primed = true
	}
}
