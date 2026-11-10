package platform

import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_pointer_pixel_density_is_independent_of_ui_scale :: proc(t: ^testing.T) {
	p := Platform {
		pixel_density = 1,
		dpi_scale     = 2,
	}
	testing.expect_value(t, window_to_pixels(&p, {100, 50}), [2]f32{100, 50})
	p.pixel_density, p.dpi_scale = 1.6, 1.6
	testing.expect_value(t, window_to_pixels(&p, {100, 50}), [2]f32{160, 80})
}

@(test)
test_frame_input_changed_ignores_transport_only_events :: proc(t: ^testing.T) {
	p: Platform
	p.had_event = true
	testing.expect(t, !frame_input_changed(&p))

	p.input.mouse = {10, 20}
	testing.expect(t, frame_input_changed(&p))
	p.input.mouse_prev = p.input.mouse
	testing.expect(t, !frame_input_changed(&p))

	// Edges are the events this frame's pump saw; held keys are state.
	p.input.key_down[.A] = true
	testing.expect(t, !frame_input_changed(&p))
	append(&p.input.events, Event{kind = .Key_Release, key = .A})
	testing.expect(t, frame_input_changed(&p))
	delete(p.input.events)
}

// Every key the set names maps from its scancode and back.
@(test)
test_key_scancodes_round_trip :: proc(t: ^testing.T) {
	for code, k in key_scancodes {
		if k == .None do continue
		testing.expect_value(t, key_of_scancode(code), k)
	}
}

// The keypad's Enter is Return (RAD's window layer maps both to it).
@(test)
test_keypad_enter_is_return :: proc(t: ^testing.T) {
	testing.expect_value(t, key_of_scancode(.KP_ENTER), Key.Enter)
	testing.expect_value(t, key_of_scancode(.RETURN), Key.Enter)
}

// As RAD's window layer: a character is text whatever the modifiers (AltGr's,
// Control and Alt together on Windows), but one with Alt alone (WM_SYSCHAR)
// isn't, except on macOS, where Option types characters.
@(test)
test_text_typed_with_modifiers :: proc(t: ^testing.T) {
	testing.expect(t, text_typed({}))
	testing.expect(t, text_typed({.Shift}))
	testing.expect(t, text_typed({.Control, .Alt}))
	testing.expect(t, text_typed({.Control}))
	testing.expect_value(t, text_typed({.Alt}), ODIN_OS == .Darwin)
}

// Focus leaving the window lets go of what is held as state, with no
// release event (RAD's), and the window counts as unfocused.
@(test)
test_focus_lost_sends_no_release :: proc(t: ^testing.T) {
	inp: Input
	defer delete(inp.events)
	inp.focused = true
	inp.mb_down[.Left] = true
	inp.key_down[.LCtrl] = true
	inp.mods = {.Control}
	input_focus_lost(&inp)
	testing.expect(t, !inp.focused && !inp.mb_down[.Left] && !inp.key_down[.LCtrl] && inp.mods == {})
	testing.expect_value(t, len(inp.events), 0)
}

// Through the pump, as SDL delivers them: focus leaving the window sends no
// release (RAD's window layer sends none), the pointer is parked at
// (-100, -100) only once the window has been unfocused and the pointer idle
// for half a second, and never while the window has the focus.
@(test)
test_pump_focus_loss_and_parking :: proc(t: ^testing.T) {
	when ODIN_OS == .Darwin {
		// events pushed from a test's thread don't come back through the pump
		// on macOS (both pump tests fail on an M4): Linux runs these
		return
	}
	if !sdl.Init({.EVENTS}) {
		testing.expectf(t, false, "SDL events: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()
	p: Platform
	defer delete(p.input.events)
	defer delete(p.input.dropped_files)
	p.input.primed, p.input.focused = true, true
	p.input.mb_down[.Left] = true
	p.input.moved_ns = sdl.GetTicksNS()
	push :: proc(type: sdl.EventType) {
		e: sdl.Event
		e.type = type
		e.window.type = type
		e.window.timestamp = sdl.GetTicksNS()
		_ = sdl.PushEvent(&e)
	}
	push(.WINDOW_FOCUS_LOST)
	_pump(&p)
	for e in p.input.events do testing.expect(t, e.kind != .Mouse_Release)
	testing.expect(t, !p.input.focused && !p.input.mb_down[.Left])
	testing.expect(t, p.input.mouse != {-100, -100}) // not idle half a second yet
	p.input.moved_ns = sdl.GetTicksNS() - 600_000_000
	_pump(&p)
	testing.expect_value(t, p.input.mouse, [2]f32{-100, -100})
	push(.WINDOW_FOCUS_GAINED)
	_pump(&p)
	testing.expect(t, p.input.focused)
	testing.expect(t, p.input.mouse != {-100, -100})
	_pump(&p)
	testing.expect(t, p.input.mouse != {-100, -100}) // focused: never parked
}

// As RAD's target_hz (raddbg_core.c:12200-12247): the display's rate for the
// first 32 frames and while the frames keep up with it; else the first
// standard rate at or below it that the frames keep within, whose signed
// difference then stops the search (RAD's own rule).
@(test)
test_frame_rate_follows_rads_targets :: proc(t: ^testing.T) {
	work :: proc(us: u64) -> (w: [64]u64) {
		for &x in w do x = us
		return
	}
	fast, slow, slower := work(5000), work(10000), work(30000)
	testing.expect_value(t, frame_target_hz(144, slow[:], 32), 144)
	testing.expect_value(t, frame_target_hz(144, fast[:], 33), 144)
	testing.expect_value(t, frame_target_hz(144, slow[:], 33), 60)
	testing.expect_value(t, frame_target_hz(60, slower[:], 33), 60)
	testing.expect_value(t, frame_target_hz(144, slow[:4], 33), 60)
}

// Through the pump: a TEXT_INPUT that comes right after a mapped KEY_DOWN is
// that press's text (`from_press`), whatever its characters, as SDL sends a
// key's text from the same handler; text on its own (an input method's
// commit), or after another event, is not.
@(test)
test_pump_marks_a_press_text :: proc(t: ^testing.T) {
	when ODIN_OS == .Darwin {
		return // as test_pump_focus_loss_and_parking
	}
	if !sdl.Init({.EVENTS}) {
		testing.expectf(t, false, "SDL events: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()
	p: Platform
	defer delete(p.input.events)
	defer delete(p.input.dropped_files)
	p.input.primed, p.input.focused = true, true
	key :: proc(code: sdl.Scancode) {
		e: sdl.Event
		e.type = .KEY_DOWN
		e.key.type = .KEY_DOWN
		e.key.scancode = code
		e.key.down = true
		e.key.timestamp = sdl.GetTicksNS()
		_ = sdl.PushEvent(&e)
	}
	text :: proc(s: cstring) {
		e: sdl.Event
		e.type = .TEXT_INPUT
		e.text.type = .TEXT_INPUT
		e.text.text = s
		e.text.timestamp = sdl.GetTicksNS()
		_ = sdl.PushEvent(&e)
	}
	editing :: proc() {
		e: sdl.Event
		e.type = .TEXT_EDITING
		e.edit.type = .TEXT_EDITING
		e.edit.text = "r"
		e.edit.timestamp = sdl.GetTicksNS()
		_ = sdl.PushEvent(&e)
	}
	motion :: proc() {
		e: sdl.Event
		e.type = .MOUSE_MOTION
		e.motion.type = .MOUSE_MOTION
		e.motion.timestamp = sdl.GetTicksNS()
		_ = sdl.PushEvent(&e)
	}
	marks :: proc(p: ^Platform) -> (out: [dynamic]bool) {
		out = make([dynamic]bool, context.temp_allocator)
		for e in p.input.events do if e.kind == .Text do append(&out, e.from_press)
		return
	}
	key(.R)
	text("к")
	text("日")
	_pump(&p)
	m := marks(&p)
	testing.expect(t, len(m) == 2 && m[0] && !m[1], "the press's text, then a commit of its own")
	key(.R)
	motion()
	text("r")
	_pump(&p)
	m = marks(&p)
	testing.expect(t, len(m) == 1 && !m[0], "after another event it isn't the press's")
	key(.RETURN)
	_pump(&p)
	m = marks(&p)
	testing.expect(t, len(m) == 1 && m[0], "Enter's newline is its press's")
	// a preedit between them (an input method's), or a key the platform
	// doesn't map: not the press's
	key(.R)
	editing()
	text("r")
	key(.INTERNATIONAL1)
	text("¥")
	_pump(&p)
	m = marks(&p)
	testing.expect(t, len(m) == 2 && !m[0] && !m[1], "after a preedit, and an unmapped key's")
	// a repeat is a press again, its text its own
	key(.R)
	text("r")
	key(.R)
	text("r")
	_pump(&p)
	m = marks(&p)
	testing.expect(t, len(m) == 2 && m[0] && m[1], "each repeat's text")
}
