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
	dpi_scale:     f32, // pixels per logical point
	should_close:  bool,
	resized:       bool, // framebuffer size changed since last tick
	input:         Input,
	// TEXT_INPUT events are on (while a text field has keyboard focus).
	text_input:    bool,

	// the native open-file dialog: one at a time; its answer arrives as a
	// dropped file
	dialog_open:   bool,
	dialog_ready:  bool,
	dialog_path:   string, // owned

	// clock
	start_ns:      u64,
	last_ns:       u64,
	frame_time:    f32, // seconds elapsed during the previous frame
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
// SPIR-V (Vulkan) or MSL (Metal) shader format. On failure `detail` is SDL's
// reason (temp memory).
init :: proc(p: ^Platform, title: cstring, w, h: i32) -> (err: Error, detail: string) {
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
	// Keep presentation deterministic across GPU backends and preserve CPU/GPU
	// overlap on slower hardware. The extra queued frame trades a small amount of
	// latency for materially better throughput than fully serialized submission.
	_ = sdl.SetGPUSwapchainParameters(p.device, p.window, .SDR, .VSYNC)
	_ = sdl.SetGPUAllowedFramesInFlight(p.device, 2)
	_update_size(p)
	p.dpi_scale = sdl.GetWindowPixelDensity(p.window)
	if p.dpi_scale <= 0 {
		p.dpi_scale = 1
	}
	p.start_ns = sdl.GetTicksNS()
	p.last_ns = p.start_ns
	return .None, ""
}

// Turns the window's text events on or off: on while a text field has
// keyboard focus, so typing elsewhere is only keys (and no input method
// shows).
text_input_set :: proc(p: ^Platform, on: bool) {
	if on == p.text_input || p.window == nil {
		return
	}
	p.text_input = on
	if on {
		_ = sdl.StartTextInput(p.window)
	} else {
		_ = sdl.StopTextInput(p.window)
	}
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
	delete(p.input.text)
	sdl.Quit()
}

// tick advances the clock and pumps one frame of events/input. Returns false when
// the window has been asked to close (drives `for platform.tick(&p) { ... }`).
tick :: proc(p: ^Platform) -> bool {
	now := sdl.GetTicksNS()
	p.frame_time = f32(f64(now - p.last_ns) / 1e9)
	p.last_ns = now
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

get_clipboard :: proc(allocator := context.temp_allocator) -> string {
	text := sdl.GetClipboardText()
	if text == nil {
		return ""
	}
	defer sdl.free(rawptr(text))
	return strings.clone(string(cstring(text)), allocator)
}

// set_fullscreen switches the window to the desktop's fullscreen mode and
// back; the size change arrives as a resize on a later tick.
set_fullscreen :: proc(p: ^Platform, on: bool) {
	_ = sdl.SetWindowFullscreen(p.window, on)
}

request_close :: proc(p: ^Platform) {
	p.should_close = true
}

_update_size :: proc(p: ^Platform) {
	pw, ph: c.int
	sdl.GetWindowSizeInPixels(p.window, &pw, &ph)
	p.width = u32(max(pw, 1))
	p.height = u32(max(ph, 1))
}
