// Package platform is the only place that touches SDL windowing, the GPU device,
// events, and the clock. Ported from ../paf/platform (itself from odincade's
// sketch_and_extrude). It exposes a native, immediate-mode-friendly surface:
// create a window + GPU device, `tick` once per frame to pump input and advance
// the clock, and query edge-detected keyboard/mouse state. No Raylib shapes.
package platform

import "base:intrinsics"
import "core:c"
import "core:c/libc"
import "core:strings"
import "core:sync"
import "core:thread"
import "base:runtime"
import sdl "vendor:sdl3"


Platform :: struct {
	window:        ^sdl.Window,
	device:        ^sdl.GPUDevice,
	width, height: u32, // framebuffer size in pixels
	dpi_scale:     f32, // framebuffer pixels per UI point (display content scale)
	pixel_density: f32, // framebuffer pixels per SDL window coordinate
	refresh_ns:    i64, // display refresh interval in nanoseconds
	// The presentation init chose: mailbox doesn't wait for vsync, so the
	// caller paces its frames.
	present_mode:  sdl.GPUPresentMode,
	should_close:  bool,
	resized:       bool, // framebuffer size changed since last tick
	had_event:     bool, // any SDL event was consumed by the current tick
	input:         Input,
	// SDL's system cursors, made at init, and the one set (set_cursor).
	cursors:       [Cursor]^sdl.Cursor,
	cursor:        Cursor,

	// the native open-file dialog: one at a time; its answer arrives as a
	// dropped file
	dialog_open:   bool,
	dialog_ready:  bool,
	dialog_path:   string, // owned

	// clock
	start_ns:      u64,
	last_ns:       u64,
	frame_time:    f32, // seconds elapsed during the previous frame
	frame_slept:   bool, // frame_time includes an idle_wait block, not frame work
	idle_slept:    bool, // set by idle_wait, handed to frame_slept by the next tick
}

// How frames reach the screen: Auto is mailbox where the window supports it,
// else vsync; Immediate runs unthrottled where supported, so a benchmark can
// read frame time as GPU time.
Present :: enum u8 {
	Auto,
	Vsync,
	Mailbox,
	Immediate,
}

// The pointer's shapes, as RAD Debugger's WM_Cursor: the arrow, an
// expander's pointing hand, a text field's I-beam, and a divider's or
// slider's resize arrows.
Cursor :: enum u8 {
	Pointer,
	Hand_Point,
	IBar,
	Left_Right,
	Up_Down,
}

// What failed to open the window (SDL's reason is the `detail` init returns).
Error :: enum u8 {
	None,
	Sdl_Init,
	Window,
	Gpu_Device,
	Claim_Window,
}

// init opens a resizable, high-DPI window backed by an SDL_GPU device using the
// SPIR-V (Vulkan) or MSL (Metal) shader format, presenting as `present`
// says. On failure `detail` is SDL's reason (temp memory).
init :: proc(p: ^Platform, title: cstring, w, h: i32, present := Present.Auto) -> (err: Error, detail: string) {
	failed :: proc(err: Error) -> (Error, string) {
		return err, strings.clone_from_cstring(sdl.GetError(), context.temp_allocator)
	}
	// Installed first, so SDL keeps them (it only takes default handlers).
	libc.signal(libc.SIGINT, _on_signal)
	libc.signal(libc.SIGTERM, _on_signal)
	thread.create_and_start(_signal_watchdog, self_cleanup = true)
	if !sdl.Init({.VIDEO}) {
		return failed(.Sdl_Init)
	}
	p.window = sdl.CreateWindow(title, w, h, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if p.window == nil {
		return failed(.Window)
	}
	p.input.focused = .INPUT_FOCUS in sdl.GetWindowFlags(p.window)
	p.input.moved_ns = sdl.GetTicksNS()
	SYSTEM_CURSORS :: [Cursor]sdl.SystemCursor{.Pointer = .DEFAULT, .Hand_Point = .POINTER, .IBar = .TEXT, .Left_Right = .EW_RESIZE, .Up_Down = .NS_RESIZE}
	for kind, c in SYSTEM_CURSORS do p.cursors[c] = sdl.CreateSystemCursor(kind)
	// SPIR-V (Vulkan) and MSL (Metal) only: ovg and the UI commit no DXIL,
	// so Windows runs SDL_GPU on Vulkan.
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true)
	_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true)
	_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, ODIN_DEBUG)
	p.device = sdl.CreateGPUDeviceWithProperties(props)
	if p.device == nil {
		return failed(.Gpu_Device)
	}
	if !sdl.ClaimWindowForGPUDevice(p.device, p.window) {
		return failed(.Claim_Window)
	}
	// Mailbox presentation: never tears, and a frame that finishes after the
	// compositor's pickup point is simply replaced by the next one; the
	// compositor gives back a buffer a newer one replaced, so taking the next
	// image never waits on it (with FIFO it waits for the display, forever
	// when the display is asleep). FIFO remains where mailbox is unsupported.
	// `present` overrides it.
	p.present_mode = .VSYNC
	if sdl.WindowSupportsGPUPresentMode(p.device, p.window, .MAILBOX) do p.present_mode = .MAILBOX
	switch present {
	case .Auto:
	case .Immediate:
		if sdl.WindowSupportsGPUPresentMode(p.device, p.window, .IMMEDIATE) do p.present_mode = .IMMEDIATE
	case .Vsync:
		p.present_mode = .VSYNC
	case .Mailbox:
		if sdl.WindowSupportsGPUPresentMode(p.device, p.window, .MAILBOX) do p.present_mode = .MAILBOX
	}
	if !sdl.SetGPUSwapchainParameters(p.device, p.window, .SDR, p.present_mode) do p.present_mode = .VSYNC
	_ = sdl.SetGPUAllowedFramesInFlight(p.device, 2)
	_update_size(p)
	_ = sdl.StartTextInput(p.window) // enable TEXT_INPUT events for line edits
	p.start_ns = sdl.GetTicksNS()
	p.last_ns = p.start_ns
	return .None, ""
}

// The dialog's filters must outlive the dialog, so they are static.
FILE_DIALOG_FILTERS := [?]sdl.DialogFileFilter {
	{"onimite scripts", "lua"},
	{"all files", "*"},
}

// file_dialog_open shows the native open-file dialog; the file picked
// arrives in `dropped_files` on a later tick.
file_dialog_open :: proc(p: ^Platform) {
	if p.dialog_open {
		return
	}
	p.dialog_open = true
	sdl.ShowOpenFileDialog(_file_dialog_done, p, p.window, &FILE_DIALOG_FILTERS[0], len(FILE_DIALOG_FILTERS), nil, false)
}

_file_dialog_done :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	p := (^Platform)(userdata)
	p.dialog_open = false
	if filelist == nil || filelist[0] == nil {
		return
	}
	delete(p.dialog_path)
	p.dialog_path = strings.clone_from_cstring(filelist[0])
	p.dialog_ready = true
}

// The chosen path, once (owned by the caller).
_file_dialog_take :: proc(p: ^Platform) -> (path: string, ok: bool) {
	if !p.dialog_ready {
		return "", false
	}
	p.dialog_ready = false
	path = p.dialog_path
	p.dialog_path = ""
	return path, true
}

shutdown :: proc(p: ^Platform) {
	delete(p.dialog_path)
	for c in p.cursors do if c != nil do sdl.DestroyCursor(c)
	if p.device != nil && p.window != nil {
		sdl.ReleaseWindowFromGPUDevice(p.device, p.window)
	}
	if p.device != nil {
		sdl.DestroyGPUDevice(p.device)
	}
	if p.window != nil {
		sdl.DestroyWindow(p.window)
	}
	input_dropped_files_clear(&p.input)
	delete(p.input.dropped_files)
	delete(p.input.events)
	sdl.Quit()
}

// tick advances the clock and pumps one frame of events/input. Returns false when
// the window has been asked to close (drives `for platform.tick(&p) { ... }`).
tick :: proc(p: ^Platform) -> bool {
	now := sdl.GetTicksNS()
	p.frame_time = f32(f64(now - p.last_ns) / 1e9)
	p.last_ns = now
	p.frame_slept = p.idle_slept
	p.idle_slept = false
	_pump(p)
	if intrinsics.atomic_load(&_signaled) {
		p.should_close = true
	}
	return !p.should_close
}

// SIGINT/SIGTERM close the window at the next tick. Presenting can block in
// the driver for as long as the display is off (DPMS), so if the process is
// still there a second later the watchdog ends it.
@(private = "file")
_signaled: bool
@(private = "file")
_signal: c.int
@(private = "file")
_signal_sema: sync.Sema

@(private = "file")
_on_signal :: proc "c" (sig: c.int) {
	intrinsics.atomic_store(&_signal, sig)
	intrinsics.atomic_store(&_signaled, true)
	sync.sema_post(&_signal_sema)
}

@(private = "file")
_signal_watchdog :: proc() {
	sync.sema_wait(&_signal_sema)
	sdl.Delay(1000)
	libc._Exit(128 + intrinsics.atomic_load(&_signal))
}

// seconds since init (analogous to a wall clock for animations).
time :: proc(p: ^Platform) -> f64 {
	return f64(sdl.GetTicksNS() - p.start_ns) / 1e9
}

set_clipboard :: proc(text: string) {
	sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}

// The clipboard's text, frame-lived; empty when it holds none.
clipboard :: proc() -> string {
	clip := sdl.GetClipboardText()
	if clip == nil do return ""
	defer sdl.free(rawptr(clip))
	return strings.clone_from_cstring(cstring(clip), context.temp_allocator)
}

// set_fullscreen switches the window to the desktop's fullscreen mode and
// back; the size change arrives as a resize on a later tick.
set_fullscreen :: proc(p: ^Platform, on: bool) {
	_ = sdl.SetWindowFullscreen(p.window, on)
}

// set_cursor_visible shows or hides the mouse cursor over the window.
set_cursor_visible :: proc(on: bool) {
	_ = sdl.ShowCursor() if on else sdl.HideCursor()
}

// set_cursor gives the pointer `c`'s shape over the window (one SDL
// couldn't make leaves the shape as it was).
set_cursor :: proc(p: ^Platform, c: Cursor) {
	if c == p.cursor do return
	p.cursor = c
	if p.cursors[c] != nil do _ = sdl.SetCursor(p.cursors[c])
}

request_close :: proc(p: ^Platform) {
	p.should_close = true
}

// The viewer uses this only after it has proven that no visible state is
// changing. Wait on SDL's queue instead of polling it at 125 Hz. Passing nil
// leaves the event queued for the next tick's single owning pump, so input wakes
// immediately without splitting event dispatch across two paths.
idle_wait :: proc(p: ^Platform, milliseconds: u32 = 250) {
	// The next tick's frame_time spans this sleep — anywhere from microseconds
	// (an event lands immediately) to the full timeout — so mark it as not
	// measuring frame work.
	p.idle_slept = true
	_ = sdl.WaitEventTimeout(nil, c.int(milliseconds))
}

// Display refresh interval in nanoseconds for `window`'s display, or the
// primary display when `window == nil`.
refresh_interval_ns :: proc(window: ^sdl.Window = nil) -> i64 {
	if .VIDEO not_in sdl.WasInit({.VIDEO}) do _ = sdl.InitSubSystem({.VIDEO})
	display := window != nil ? sdl.GetDisplayForWindow(window) : 0
	if display == 0 do display = sdl.GetPrimaryDisplay()
	mode := sdl.GetCurrentDisplayMode(display)
	if mode == nil do mode = sdl.GetDesktopDisplayMode(display)
	rate := mode != nil && mode.refresh_rate > 0 ? f64(mode.refresh_rate) : 60.0
	return i64(1e9 / rate)
}

_update_size :: proc(p: ^Platform) {
	pw, ph: c.int
	sdl.GetWindowSizeInPixels(p.window, &pw, &ph)
	p.width = u32(max(pw, 1))
	p.height = u32(max(ph, 1))
	p.pixel_density = sdl.GetWindowPixelDensity(p.window)
	if p.pixel_density <= 0 do p.pixel_density = 1
	p.dpi_scale = sdl.GetWindowDisplayScale(p.window)
	if p.dpi_scale <= 0 do p.dpi_scale = p.pixel_density
	p.refresh_ns = refresh_interval_ns(p.window)
}
