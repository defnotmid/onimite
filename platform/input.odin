package platform

import "core:c"
import "core:strings"
import sdl "vendor:sdl3"

// The keyboard's keys, by position (SDL scancodes, mapped below).
Key :: enum u8 {
	None,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	Zero,
	One,
	Two,
	Three,
	Four,
	Five,
	Six,
	Seven,
	Eight,
	Nine,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	Space,
	Enter,
	Escape,
	Backspace,
	Delete,
	Tab,
	Home,
	End,
	Page_Up,
	Page_Down,
	Insert,
	Left,
	Right,
	Up,
	Down,
	Grave,
	Minus,
	Equal,
	Left_Bracket,
	Right_Bracket,
	Backslash,
	Semicolon,
	Apostrophe,
	Comma,
	Period,
	Slash,
	Caps_Lock,
	Scroll_Lock,
	Num_Lock,
	Print_Screen,
	Pause,
	Menu,
	Num_0,
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,
	Num_Slash,
	Num_Star,
	Num_Minus,
	Num_Plus,
	Num_Period,
	LShift,
	RShift,
	LCtrl,
	RCtrl,
	LAlt,
	RAlt,
}

Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
}

// A modifier held with an event; Control is ⌘ on macOS.
Modifier :: enum u8 {
	Control,
	Shift,
	Alt,
}
Modifiers :: bit_set[Modifier;u8]

// One OS event, as RAD Debugger's window layer gives them (WM_Event): in
// the order they came, each at its own pointer position with the modifiers
// held then. A key's press (`repeat`: auto-repeated while held) or release;
// a mouse button's; a character typed (Enter types '\n', as RAD's window
// layer gives it; a chord with Control or Alt types nothing); the wheel, in
// RAD's units (120 a notch, right and down positive).
Event_Kind :: enum u8 {
	Key_Press,
	Key_Release,
	Mouse_Press,
	Mouse_Release,
	Text,
	Scroll,
}
Event :: struct {
	kind:      Event_Kind,
	key:       Key,
	button:    Mouse_Button,
	repeat:    bool,
	modifiers: Modifiers,
	position:  [2]f32, // pixels
	delta:     [2]f32, // Scroll
	character: rune, // Text
	// Text the key press just before it typed: SDL sends a key's text back
	// to back with its KEY_DOWN, from the same handler, where an input
	// method's commit comes on its own (oui's and onib's rule).
	from_press: bool,
}
// RAD's wheel units a notch (WHEEL_DELTA).
WHEEL_NOTCH :: 120

Input :: struct {
	key_down:      [Key]bool, // level state, from events
	mb_down:       [Mouse_Button]bool,
	mouse:         [2]f32, // pixels
	mouse_prev:    [2]f32,
	mouse_delta:   [2]f32,
	events:        [dynamic]Event, // this frame's, in order
	// The modifiers held, as SDL reports them at the last key event (AltGr
	// is its MODE, not Alt), seeded when focus arrives.
	mods:          Modifiers,
	// Whether the window has the keyboard's focus; unfocused, the pointer
	// is away (at -100, -100, as RAD's) half a second after it last moved.
	focused:       bool,
	// The last SDL event was a mapped KEY_DOWN: a TEXT_INPUT now is its
	// text (`from_press`).
	after_press:   bool,
	moved_ns:      u64,
	dropped_files: [dynamic]string, // dropped on the window or picked in the open-file dialog this frame (owned)
	primed:        bool, // first tick has established button state
	user_seen:     bool, // a real motion, button, or key event has arrived
}

// The SDL scancode of each Key.
key_scancodes := [Key]sdl.Scancode {
	.None          = .UNKNOWN,
	.A             = .A,
	.B             = .B,
	.C             = .C,
	.D             = .D,
	.E             = .E,
	.F             = .F,
	.G             = .G,
	.H             = .H,
	.I             = .I,
	.J             = .J,
	.K             = .K,
	.L             = .L,
	.M             = .M,
	.N             = .N,
	.O             = .O,
	.P             = .P,
	.Q             = .Q,
	.R             = .R,
	.S             = .S,
	.T             = .T,
	.U             = .U,
	.V             = .V,
	.W             = .W,
	.X             = .X,
	.Y             = .Y,
	.Z             = .Z,
	.Zero          = ._0,
	.One           = ._1,
	.Two           = ._2,
	.Three         = ._3,
	.Four          = ._4,
	.Five          = ._5,
	.Six           = ._6,
	.Seven         = ._7,
	.Eight         = ._8,
	.Nine          = ._9,
	.F1            = .F1,
	.F2            = .F2,
	.F3            = .F3,
	.F4            = .F4,
	.F5            = .F5,
	.F6            = .F6,
	.F7            = .F7,
	.F8            = .F8,
	.F9            = .F9,
	.F10           = .F10,
	.F11           = .F11,
	.F12           = .F12,
	.F13           = .F13,
	.F14           = .F14,
	.F15           = .F15,
	.F16           = .F16,
	.F17           = .F17,
	.F18           = .F18,
	.F19           = .F19,
	.F20           = .F20,
	.F21           = .F21,
	.F22           = .F22,
	.F23           = .F23,
	.F24           = .F24,
	.Space         = .SPACE,
	.Enter         = .RETURN,
	.Escape        = .ESCAPE,
	.Backspace     = .BACKSPACE,
	.Delete        = .DELETE,
	.Tab           = .TAB,
	.Home          = .HOME,
	.End           = .END,
	.Page_Up       = .PAGEUP,
	.Page_Down     = .PAGEDOWN,
	.Insert        = .INSERT,
	.Left          = .LEFT,
	.Right         = .RIGHT,
	.Up            = .UP,
	.Down          = .DOWN,
	.Grave         = .GRAVE,
	.Minus         = .MINUS,
	.Equal         = .EQUALS,
	.Left_Bracket  = .LEFTBRACKET,
	.Right_Bracket = .RIGHTBRACKET,
	.Backslash     = .BACKSLASH,
	.Semicolon     = .SEMICOLON,
	.Apostrophe    = .APOSTROPHE,
	.Comma         = .COMMA,
	.Period        = .PERIOD,
	.Slash         = .SLASH,
	.Caps_Lock     = .CAPSLOCK,
	.Scroll_Lock   = .SCROLLLOCK,
	.Num_Lock      = .NUMLOCKCLEAR,
	.Print_Screen  = .PRINTSCREEN,
	.Pause         = .PAUSE,
	.Menu          = .APPLICATION,
	.Num_0         = .KP_0,
	.Num_1         = .KP_1,
	.Num_2         = .KP_2,
	.Num_3         = .KP_3,
	.Num_4         = .KP_4,
	.Num_5         = .KP_5,
	.Num_6         = .KP_6,
	.Num_7         = .KP_7,
	.Num_8         = .KP_8,
	.Num_9         = .KP_9,
	.Num_Slash     = .KP_DIVIDE,
	.Num_Star      = .KP_MULTIPLY,
	.Num_Minus     = .KP_MINUS,
	.Num_Plus      = .KP_PLUS,
	.Num_Period    = .KP_PERIOD,
	.LShift        = .LSHIFT,
	.RShift        = .RSHIFT,
	// LCtrl/RCtrl are the ⌘ keys on macOS.
	.LCtrl         = .LGUI when ODIN_OS == .Darwin else .LCTRL,
	.RCtrl         = .RGUI when ODIN_OS == .Darwin else .RCTRL,
	.LAlt          = .LALT,
	.RAlt          = .RALT,
}

// The Key of an SDL scancode, .None for a key the set doesn't name; the
// keypad's Enter is Return (RAD's window layer maps both to it).
key_of_scancode :: proc(sc: sdl.Scancode) -> Key {
	if sc == .UNKNOWN do return .None
	if sc == .KP_ENTER do return .Enter
	for code, k in key_scancodes do if code == sc do return k
	return .None
}

// ---- per-frame queries ----
// Edges are the events themselves (`events`), in order, not a diff of
// level state between ticks: a press and release that land in the same
// pump (a fast tap) are both there, each where it happened.
key_down :: proc(p: ^Platform, k: Key) -> bool {return p.input.key_down[k]}
mouse_down :: proc(p: ^Platform, b: Mouse_Button) -> bool {return p.input.mb_down[b]}
mouse_pos :: proc(p: ^Platform) -> [2]f32 {return p.input.mouse}
mouse_delta :: proc(p: ^Platform) -> [2]f32 {return p.input.mouse_delta}
events :: proc(p: ^Platform) -> []Event {return p.input.events[:]}
dropped_files :: proc(p: ^Platform) -> []string {return p.input.dropped_files[:]}

any_input_down :: proc(p: ^Platform) -> bool {
	for down in p.input.key_down do if down do return true
	for down in p.input.mb_down do if down do return true
	return false
}

// Events are transport; only changed input data invalidates presentation. SDL
// may deliver window/device events that have no visible consequence, so the
// viewer must not turn the broad `had_event` bit into a permanent render clock.
frame_input_changed :: proc(p: ^Platform) -> bool {
	inp := &p.input
	return len(inp.events) > 0 || inp.mouse != inp.mouse_prev || len(inp.dropped_files) > 0
}

// The modifiers a key event carries (SDL's, at the event).
modifiers_of_keymod :: proc(mods: sdl.Keymod) -> (out: Modifiers) {
	control := (.LGUI in mods || .RGUI in mods) when ODIN_OS == .Darwin else (.LCTRL in mods || .RCTRL in mods)
	if control do out += {.Control}
	if .LSHIFT in mods || .RSHIFT in mods do out += {.Shift}
	if .LALT in mods || .RALT in mods do out += {.Alt}
	return
}

// Whether a character typed with `mods` held is text: as RAD's window
// layer keeps WM_CHAR whatever the modifiers (AltGr's characters, Control
// and Alt together on Windows, among them) and drops WM_SYSCHAR, a
// character with Alt and no Control. On macOS Option (Alt) types
// characters, and there is no WM_SYSCHAR to drop.
text_typed :: proc(mods: Modifiers) -> bool {
	when ODIN_OS == .Darwin do return true
	return .Alt not_in mods || .Control in mods
}

// The window loses the keyboard's focus: what is held is let go as level
// state, with no release (RAD's window layer sends none, and its UI keeps
// the box a press made active).
input_focus_lost :: proc(inp: ^Input) {
	inp.focused = false
	inp.mb_down = {}
	inp.key_down = {}
	inp.mods = {}
}

input_dropped_files_clear :: proc(inp: ^Input) {
	for path in inp.dropped_files {
		delete(path)
	}
	clear(&inp.dropped_files)
}

// A mouse button's event at `at` (window coordinates): its level state and
// its press or release, in order.
input_button :: proc(p: ^Platform, button: u8, down: bool, at: [2]f32) {
	inp := &p.input
	b: Mouse_Button
	switch button {
	case sdl.BUTTON_LEFT:
		b = .Left
	case sdl.BUTTON_MIDDLE:
		b = .Middle
	case sdl.BUTTON_RIGHT:
		b = .Right
	case:
		return
	}
	inp.mb_down[b] = down
	append(&inp.events, Event{kind = .Mouse_Press if down else .Mouse_Release, button = b, modifiers = inp.mods, position = window_to_pixels(p, at)})
}

_pump :: proc(p: ^Platform) {
	inp := &p.input
	inp.mouse_prev = inp.mouse
	clear(&inp.events)
	input_dropped_files_clear(inp)
	p.resized = false
	p.had_event = false

	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		p.had_event = true
		// (a mapped KEY_DOWN: the TEXT_INPUT right after it is its text)
		pressed := false
		defer inp.after_press = pressed
		#partial switch ev.type {
		case .QUIT:
			p.should_close = true
		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED, .WINDOW_DISPLAY_SCALE_CHANGED, .WINDOW_DISPLAY_CHANGED:
			_update_size(p)
			p.resized = true
		case .MOUSE_WHEEL:
			// RAD's units: a notch is 120, down and right positive.
			at := window_to_pixels(p, {ev.wheel.mouse_x, ev.wheel.mouse_y})
			append(&inp.events, Event{kind = .Scroll, modifiers = inp.mods, position = at, delta = {ev.wheel.x, -ev.wheel.y} * WHEEL_NOTCH})
		case .KEY_DOWN:
			inp.user_seen = true
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: key %v down repeat=%v (t=%.2f)", ev.key.scancode, ev.key.repeat, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
			// A repeat is flagged by SDL, or arrives as a second KEY_DOWN for
			// a key still down (SDL3 on Wayland sends compositor repeats that
			// way, with the flag clear); both count as typed again.
			if k := key_of_scancode(ev.key.scancode); k != .None {
				mods := modifiers_of_keymod(ev.key.mod)
				inp.mods = mods
				append(&inp.events, Event{kind = .Key_Press, key = k, repeat = ev.key.repeat || inp.key_down[k], modifiers = mods, position = inp.mouse})
				inp.key_down[k] = true
				// Enter types a newline, as RAD's window layer gives it.
				if k == .Enter && mods & {.Control, .Alt} == {} {
					append(&inp.events, Event{kind = .Text, modifiers = mods, position = inp.mouse, character = '\n', from_press = true})
				}
				pressed = true
			}
		case .KEY_UP:
			inp.mods = modifiers_of_keymod(ev.key.mod)
			if k := key_of_scancode(ev.key.scancode); k != .None {
				inp.key_down[k] = false
				append(&inp.events, Event{kind = .Key_Release, key = k, modifiers = inp.mods, position = inp.mouse})
			}
		case .MOUSE_MOTION:
			inp.user_seen = true
			inp.mouse = window_to_pixels(p, {ev.motion.x, ev.motion.y})
			inp.moved_ns = sdl.GetTicksNS()
		case .MOUSE_BUTTON_DOWN:
			inp.user_seen = true
			input_button(p, ev.button.button, true, {ev.button.x, ev.button.y})
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: button %d down at %.0f,%.0f (t=%.2f)", ev.button.button, ev.button.x, ev.button.y, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
		case .MOUSE_BUTTON_UP:
			input_button(p, ev.button.button, false, {ev.button.x, ev.button.y})
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: button %d up at %.0f,%.0f (t=%.2f)", ev.button.button, ev.button.x, ev.button.y, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
		case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST, .WINDOW_MOUSE_ENTER, .WINDOW_MOUSE_LEAVE:
			// Buttons and keys held across a focus or pointer boundary are
			// let go here as state, with no release (RAD's): the compositor
			// will not tell us later.
			if ev.type == .WINDOW_MOUSE_LEAVE do inp.mb_down = {}
			if ev.type == .WINDOW_FOCUS_LOST do input_focus_lost(inp)
			if ev.type == .WINDOW_FOCUS_GAINED {
				// Keys already held when focus arrives never send KEY_DOWN;
				// seed them from the level state once, as state, not edges.
				inp.focused = true
				inp.mods = modifiers_of_keymod(sdl.GetModState())
				nkeys: c.int
				ks := sdl.GetKeyboardState(&nkeys)
				inp.key_down = {}
				for code, k in key_scancodes {
					if code != .UNKNOWN && int(code) < int(nkeys) && ks[int(code)] {
						inp.key_down[k] = true
					}
				}
			}
			when #config(ONIMITE_INPUT_DEBUG, false) {
				fmt.eprintfln("input: window event %v (t=%.2f)", ev.type, f64(sdl.GetTicksNS() - p.start_ns) / 1e9)
			}
		case .TEXT_INPUT:
			// A character an event, as RAD's, whatever the modifiers but
			// Alt alone (text_typed).
			if mods := inp.mods; ev.text.text != nil && text_typed(mods) {
				for r in string(ev.text.text) do append(&inp.events, Event{kind = .Text, modifiers = mods, position = inp.mouse, character = r, from_press = inp.after_press})
			}
		case .DROP_FILE:
			if ev.drop.data != nil {
				append(&inp.dropped_files, strings.clone(string(ev.drop.data)))
			}
		}
	}
	// A file picked in the open-file dialog arrives like a dropped one.
	if path, ok := _file_dialog_take(p); ok {
		append(&inp.dropped_files, path)
	}

	// Key and button state comes from the events above, never from SDL's
	// polled level state: on Wayland the polled mask can report a button as
	// held for a moment when the pointer is warped into a freshly focused
	// window, which read as a click on whatever sat under it.

	// SDL window coordinates use pixel density, not the user's UI scale.
	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)
	inp.mouse = window_to_pixels(p, {mx, my})
	// Unfocused and not moved for half a second, the pointer is away (RAD's).
	if !inp.focused && sdl.GetTicksNS() - inp.moved_ns > 500_000_000 do inp.mouse = {-100, -100}
	inp.mouse_delta = inp.mouse - inp.mouse_prev
	// A button already held when the window appears is state, not an edge:
	// without this the first tick reports a press wherever the cursor sits
	// and the matching release becomes a click on that widget.
	if !inp.primed {
		clear(&inp.events)
		inp.mouse_prev = inp.mouse
		inp.mouse_delta = {}
		inp.primed = true
	}
}

window_to_pixels :: proc(p: ^Platform, point: [2]f32) -> [2]f32 {
	return point * (p.pixel_density > 0 ? p.pixel_density : 1)
}
