// Package render draws the preview's UI frame, as onib draws its own: ovg
// draws the whole frame (the UI's boxes and text, the timeline, the video
// frame and thumbnails other threads render) as one canvas into the frame
// image, recording into the frame's command buffer, and the image is shown.
package render

import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"
import sdl "vendor:sdl3"

Renderer :: struct {
	device:      ^sdl.GPUDevice,
	window:      ^sdl.Window,
	fb_w, fb_h:  u32,
	backend:     vgsdl.SDL_Backend,
	canvas:      vg.Canvas,
	// The image the frame is drawn into, at the frame's size (frame_w x
	// frame_h): shown, or read back by end_frame_capture.
	frame:       vg.Image_Id,
	frame_w:     u32,
	frame_h:     u32,
	// The shape being drawn.
	path:        vg.Path,
	// Images showing textures made elsewhere (draw_image_*), pointed at
	// this frame's textures in order: the first `shown` drawn this frame.
	borrowed:    [dynamic]vg.Image_Id,
	shown:       int,
	// clip_push's saves not yet popped.
	clips:       int,
	// Textures released once the frame drawing them is submitted.
	retired:     [dynamic]^sdl.GPUTexture,
	// The window presents in mailbox mode, which doesn't wait for vsync:
	// the caller paces its frames.
	mailbox:     bool,
}

// What failed to set up the UI's drawing.
Error :: enum u8 {
	None,
	// ovg's GPU backend didn't start on the device.
	Backend,
	// The UI's font doesn't load.
	Font,
}

@(private)
FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

init :: proc(r: ^Renderer, device: ^sdl.GPUDevice, window: ^sdl.Window, fb_w, fb_h: u32) -> Error {
	r.device = device
	r.window = window
	r.fb_w, r.fb_h = max(fb_w, 1), max(fb_h, 1)
	// Mailbox where the window takes it: the compositor gives back a buffer
	// a newer one replaced, so taking the next image never waits on it. With
	// FIFO it waits for the display, forever when the display is asleep.
	if sdl.WindowSupportsGPUPresentMode(device, window, .MAILBOX) {
		r.mailbox = sdl.SetGPUSwapchainParameters(device, window, .SDR, .MAILBOX)
	}
	if vgsdl.init(&r.backend, device) != nil {
		return .Backend
	}
	vg.canvas_init(&r.canvas, vgsdl.backend(&r.backend))
	return nil
}

shutdown :: proc(r: ^Renderer) {
	if r.device != nil {
		_ = sdl.WaitForGPUIdle(r.device)
	}
	release_retired(r)
	delete(r.retired)
	delete(r.borrowed)
	vg.path_destroy(&r.path)
	vg.canvas_destroy(&r.canvas)
	vgsdl.destroy(&r.backend)
}

resize :: proc(r: ^Renderer, fb_w, fb_h: u32) {
	r.fb_w, r.fb_h = max(fb_w, 1), max(fb_h, 1)
}

// Queue a texture for release once the frame that may draw it is submitted.
defer_release_texture :: proc(r: ^Renderer, texture: ^sdl.GPUTexture) {
	if r != nil && texture != nil {
		append(&r.retired, texture)
	}
}

// SDL releases each when the submitted work using it is done.
@(private)
release_retired :: proc(r: ^Renderer) {
	for t in r.retired {
		sdl.ReleaseGPUTexture(r.device, t)
	}
	clear(&r.retired)
}

// ---- frame ----

// Starts the frame: everything drawn until end_frame goes into the frame
// image, cleared to `clear_col` (straight alpha).
begin_frame :: proc(r: ^Renderer, clear_col: [4]f32) -> bool {
	c := &r.canvas
	if !vg.image_id_valid(r.frame) {
		r.frame, _ = vg.create_image_empty(c, r.fb_w, r.fb_h, .RGBA8, {.Premultiplied})
	} else if r.fb_w != r.frame_w || r.fb_h != r.frame_h {
		vg.realloc_image(c, r.frame, r.fb_w, r.fb_h, .RGBA8, {.Premultiplied})
	}
	r.frame_w, r.frame_h = r.fb_w, r.fb_h
	r.shown = 0
	r.clips = 0
	vg.set_size(c, r.fb_w, r.fb_h)
	vg.reset_transform(c)
	vg.reset_scissor(c)
	vg.set_render_target(c, r.frame)
	vg.clear_rect(c, 0, 0, r.fb_w, r.fb_h, {clear_col[0], clear_col[1], clear_col[2], clear_col[3]})
	return true
}

// Draws the frame and shows it, if the window takes it: whether it did.
// The window's thread never waits on the compositor: a window nobody sees
// (hidden, minimized, occluded, or on a display that's asleep, which no
// flag tells) may never get a swapchain image back, and none ready shows
// nothing this time. The caller paces.
end_frame :: proc(r: ^Renderer) -> (shown: bool) {
	c := &r.canvas
	vg.set_render_target(c, nil)
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	out := vgsdl.Output{nil, FORMAT, r.frame_w, r.frame_h, cmd}
	vg.flush(c, vgsdl.output(&out))
	unseen := sdl.GetWindowFlags(r.window) & {.HIDDEN, .MINIMIZED, .OCCLUDED} != {}
	swap: ^sdl.GPUTexture
	sw, sh: u32
	if !unseen && sdl.AcquireGPUSwapchainTexture(cmd, r.window, &swap, &sw, &sh) && swap != nil {
		sdl.BlitGPUTexture(cmd, {source = {texture = vgsdl.image_texture(c, r.frame), w = r.frame_w, h = r.frame_h}, destination = {texture = swap, w = sw, h = sh}, load_op = .DONT_CARE, filter = .LINEAR})
		if sw != r.fb_w || sh != r.fb_h {
			resize(r, sw, sh)
		}
		shown = true
	}
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	release_retired(r)
	return
}

// end_frame_capture finishes the frame into the frame image and returns it
// as tightly packed RGBA8 (for smoke tests and screenshots without a
// compositor).
end_frame_capture :: proc(r: ^Renderer, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	c := &r.canvas
	vg.set_render_target(c, nil)
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	out := vgsdl.Output{nil, FORMAT, r.frame_w, r.frame_h, cmd}
	vg.flush(c, vgsdl.output(&out))
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		return nil, false
	}
	_ = sdl.WaitForGPUFences(r.device, true, &fence, 1)
	sdl.ReleaseGPUFence(r.device, fence)
	release_retired(r)
	read, err := vg.read_image(c, r.frame, allocator)
	return read, err == nil
}
