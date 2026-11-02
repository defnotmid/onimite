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
