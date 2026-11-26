// Package render is the preview's SDL3 frame, as onib's: ovg draws the
// whole frame (the UI's boxes and text, the timeline, the video frame and
// thumbnails other threads render, `Picture`s) as one canvas into the frame
// image, then the image is shown. On the window's GPU device the canvas
// records into the frame's command buffer and the image's texture is
// blitted to the swapchain; with no device (a machine whose only GPU is a
// software one, or none) the canvas draws on the CPU and the image's
// pixels are copied into the window's surface, which SDL shows without a
// GPU.
package render

import "core:time"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"
import vgsoft "deps:ovg/sdlsoft"
import sdl "vendor:sdl3"

Renderer :: struct {
	// Nil: the frame is drawn on the CPU and shown through the window's
	// surface.
	device:     ^sdl.GPUDevice,
	window:     ^sdl.Window,
	// What other threads draw for the window (image_borrow).
	pictures:   ^Pictures,
	fb_w, fb_h: u32,
	// The ovg image the frame is drawn into (so its layers can read what is
	// drawn, as a backdrop blur does), shown each frame or read back by
	// end_frame_capture.
	frame:      vg.Image_Id,
	retired:    [dynamic]^sdl.GPUTexture, // released after the next submit
	// onimite: images showing textures made elsewhere (the worker's video
	// frame, thumbnails, band strips; image_borrow), pointed at this frame's
	// textures in order: the first `shown` drawn this frame.
	borrowed:   [dynamic]vg.Image_Id,
	shown:      int,
	// No device: shows the frame image's pixels in the window's surface.
	presenter:  vgsoft.Presenter,
}

// What failed to set up the preview's drawing (onimite).
Error :: enum u8 {
	None,
	// ovg's GPU backend didn't start on the device.
	Backend,
	// The UI's font doesn't load.
	Font,
}

FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM
texture :: proc(device: ^sdl.GPUDevice, w, h: u32, format := FORMAT) -> ^sdl.GPUTexture {
	return sdl.CreateGPUTexture(device, {type = .D2, format = format, usage = {.SAMPLER, .COLOR_TARGET}, width = w, height = h, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
}
init :: proc(r: ^Renderer, device: ^sdl.GPUDevice, window: ^sdl.Window, pictures: ^Pictures) {
	r.device, r.window, r.pictures = device, window, pictures
	vgsoft.presenter_init(&r.presenter, window)
}
defer_release_texture :: proc(r: ^Renderer, t: ^sdl.GPUTexture) {if t != nil do append(&r.retired, t)}
destroy :: proc(r: ^Renderer) {
	if r.device != nil {
		_ = sdl.WaitForGPUIdle(r.device)
		for t in r.retired do sdl.ReleaseGPUTexture(r.device, t)
	}
	vgsoft.presenter_destroy(&r.presenter)
	delete(r.retired)
	delete(r.borrowed)
}
// The frame image, at the window's size: made on the first frame, resized
// in place (the same id) when the window is.
begin_frame :: proc(r: ^Renderer, c: ^vg.Canvas, w, h: u32) -> vg.Image_Id {
	if !vg.image_id_valid(r.frame) {
		r.frame, _ = vg.create_image_empty(c, w, h, .RGBA8, {.Premultiplied})
	} else if w != r.fb_w || h != r.fb_h {
		vg.realloc_image(c, r.frame, w, h, .RGBA8, {.Premultiplied})
	}
	r.fb_w, r.fb_h = w, h
	r.shown = 0
	return r.frame
}
// Run what `c` recorded this frame (all of it into the frame image) and show
// the image, if the window takes it (`shown`). Returns the time spent
// flushing `c` to the GPU command buffer, before swapchain acquisition.
// onimite: the window's thread never waits on the compositor: a window
// nobody sees (hidden, minimized, occluded, or on a display that's asleep,
// which no flag tells) may never get a swapchain image back, and none ready
// shows nothing this time. The caller paces.
end_frame :: proc(r: ^Renderer, c: ^vg.Canvas) -> (flush_ns: i64, shown: bool) {
	t0 := time.tick_now()
	unseen := sdl.GetWindowFlags(r.window) & {.HIDDEN, .MINIMIZED, .OCCLUDED} != {}
	if r.device == nil {
		vg.flush(c)
		flush_ns = i64(time.tick_diff(t0, time.tick_now()))
		// The frame image's pixels (premultiplied over an opaque background),
		// copied into the window's surface.
		if src, ok := vg.software_backend_image(c, r.frame); ok && !unseen {
			shown = vgsoft.present_pixels(&r.presenter, src)
		}
		pictures_after_frame(r.pictures, c)
		return
	}
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	out := vgsdl.Output{nil, FORMAT, r.fb_w, r.fb_h, cmd}
	vg.flush(c, vgsdl.output(&out))
	flush_ns = i64(time.tick_diff(t0, time.tick_now()))
	swap: ^sdl.GPUTexture; w, h: u32
	if !unseen && sdl.AcquireGPUSwapchainTexture(cmd, r.window, &swap, &w, &h) && swap != nil {
		sdl.BlitGPUTexture(cmd, {source = {texture = vgsdl.image_texture(c, r.frame), w = r.fb_w, h = r.fb_h}, destination = {texture = swap, w = w, h = h}, load_op = .DONT_CARE, filter = .LINEAR})
		shown = true
	}
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	for t in r.retired do sdl.ReleaseGPUTexture(r.device, t)
	clear(&r.retired)
	return
}

// onimite: end_frame_capture finishes the frame into the frame image and
// returns it as tightly packed RGBA8 (for smoke tests and screenshots
// without a compositor).
end_frame_capture :: proc(r: ^Renderer, c: ^vg.Canvas, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	if r.device == nil {
		vg.flush(c)
		pictures_after_frame(r.pictures, c)
		read, err := vg.read_image(c, r.frame, allocator)
		return read, err == nil
	}
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	out := vgsdl.Output{nil, FORMAT, r.fb_w, r.fb_h, cmd}
	vg.flush(c, vgsdl.output(&out))
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil do return nil, false
	_ = sdl.WaitForGPUFences(r.device, true, &fence, 1)
	sdl.ReleaseGPUFence(r.device, fence)
	for t in r.retired do sdl.ReleaseGPUTexture(r.device, t)
	clear(&r.retired)
	read, err := vg.read_image(c, r.frame, allocator)
	return read, err == nil
}

// onimite: picture `p` (made on another thread) as an image to paint with
// vg.paint_image: a texture as the next of the frame's borrowed images, a
// software picture as its own image (pictures_run wrote it).
image_borrow :: proc(r: ^Renderer, c: ^vg.Canvas, p: Picture, flags: vg.Image_Flags = {}) -> vg.Image_Id {
	if p.texture == nil {
		if p.key == 0 || int(p.key) > len(r.pictures.images) do return {}
		id := r.pictures.images[p.key - 1]
		if info, ok := vg.image_info(c, id); ok && info.flags != flags {
			info.flags = flags
			vg.image_set_info(c, id, info)
		}
		return id
	}
	if r.shown == len(r.borrowed) do append(&r.borrowed, vg.Image_Id{})
	r.borrowed[r.shown] = vgsdl.image_borrow_texture(c, r.borrowed[r.shown], p.texture, p.size.x, p.size.y, .RGBA8, flags)
	r.shown += 1
	return r.borrowed[r.shown - 1]
}
