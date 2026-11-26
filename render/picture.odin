package render

import "base:runtime"
import "core:sync"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"
import sdl "vendor:sdl3"

// A picture a thread other than the window's draws for the window to show
// (the preview's video frames, thumbnails, band strips and media images): a
// texture on the window's GPU device or, where the window has none, an image
// on its software canvas. Other threads make, write and let go of either
// through the window's `Pictures`. A software picture's rows wait in its
// queue until the window's thread runs them before it draws
// (pictures_run), as SDL's queue runs a texture's uploads before the frames
// that draw it; so a thread writes a picture the same way on both, and only
// the window's thread touches a software picture's pixels.
Picture :: struct {
	texture: ^sdl.GPUTexture,
	// A software picture: 1 + its row in the window's images (0: none).
	key:     u32,
	size:    [2]u32,
}

// What another thread asked of a software picture, in order.
@(private)
Picture_Op :: struct {
	key:   u32,
	kind:  enum u8 {
		Make,
		Write,
		Free,
	},
	// Make: 0, 0 and its size; Write: x, y, width, height.
	rect:  [4]u32,
	// Write: where its pixels (rect's, tightly packed RGBA8) start in the
	// queue's bytes.
	bytes: int,
}

// The window's pictures: textures on its GPU device (`device`), or software
// pictures, whose rows other threads queue and the window's thread runs.
Pictures :: struct {
	device:    ^sdl.GPUDevice,
	// Queued by other threads, under `mutex`, with the keys given back.
	mutex:     sync.Mutex,
	ops:       [dynamic]Picture_Op,
	bytes:     [dynamic]u8,
	free_keys: [dynamic]u32,
	keys:      u32,
	// The window's thread's: the rows taken from the queue (the two swap
	// each frame), the images by key - 1, and the keys let go of this frame,
	// whose images go once it is shown.
	run_ops:   [dynamic]Picture_Op,
	run_bytes: [dynamic]u8,
	images:    [dynamic]vg.Image_Id,
	freeing:   [dynamic]u32,
}

pictures_destroy :: proc(ps: ^Pictures) {
	delete(ps.ops)
	delete(ps.bytes)
	delete(ps.free_keys)
	delete(ps.run_ops)
	delete(ps.run_bytes)
	delete(ps.images)
	delete(ps.freeing)
}

// A picture `size` big, for any thread: a texture on the device (`target`:
// one a GPU canvas draws into), else a software picture, written before the
// window draws it. Zero when the device has no texture to give.
picture_make :: proc(ps: ^Pictures, size: [2]u32, target := false) -> Picture {
	if ps.device != nil {
		usage := sdl.GPUTextureUsageFlags{.SAMPLER}
		if target do usage += {.COLOR_TARGET}
		texture := sdl.CreateGPUTexture(ps.device, {type = .D2, format = .R8G8B8A8_UNORM, usage = usage, width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1})
		return {texture = texture, size = size} if texture != nil else {}
	}
	sync.guard(&ps.mutex)
	key: u32
	if n := len(ps.free_keys); n > 0 {
		key = pop(&ps.free_keys)
	} else {
		ps.keys += 1
		key = ps.keys
	}
	append(&ps.ops, Picture_Op{key = key, kind = .Make, rect = {0, 0, size.x, size.y}})
	return {key = key, size = size}
}

// `pixels` (RGBA8, tightly packed) into `rect` (x, y, width, height) of `p`,
// for any thread. A texture's upload runs on the device's queue before any
// frame that draws it (`wait`: and has run when this returns); a software
// picture's, on the window's thread before it draws.
picture_write :: proc(ps: ^Pictures, p: Picture, pixels: []u8, rect: [4]u32, wait := false) {
	n := int(rect[2] * rect[3] * 4)
	if n == 0 || len(pixels) < n {
		return
	}
	if p.texture != nil {
		tb := sdl.CreateGPUTransferBuffer(ps.device, {usage = .UPLOAD, size = u32(n)})
		if tb == nil {
			return
		}
		// (SDL frees it once the upload has run.)
		defer sdl.ReleaseGPUTransferBuffer(ps.device, tb)
		dst := sdl.MapGPUTransferBuffer(ps.device, tb, false)
		if dst == nil {
			return
		}
		runtime.mem_copy_non_overlapping(dst, raw_data(pixels), n)
		sdl.UnmapGPUTransferBuffer(ps.device, tb)
		cb := sdl.AcquireGPUCommandBuffer(ps.device)
		pass := sdl.BeginGPUCopyPass(cb)
		sdl.UploadToGPUTexture(pass, {transfer_buffer = tb, pixels_per_row = rect[2], rows_per_layer = rect[3]}, {texture = p.texture, x = rect[0], y = rect[1], w = rect[2], h = rect[3], d = 1}, false)
		sdl.EndGPUCopyPass(pass)
		if !wait {
			_ = sdl.SubmitGPUCommandBuffer(cb)
			return
		}
		fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cb)
		if fence != nil {
			fences := [1]^sdl.GPUFence{fence}
			_ = sdl.WaitForGPUFences(ps.device, true, &fences[0], 1)
			sdl.ReleaseGPUFence(ps.device, fence)
		}
		return
	}
	if p.key == 0 {
		return
	}
	sync.guard(&ps.mutex)
	start := len(ps.bytes)
	append(&ps.bytes, ..pixels[:n])
	append(&ps.ops, Picture_Op{key = p.key, kind = .Write, rect = rect, bytes = start})
}

// Lets go of `p`, for any thread: a texture retires to `retired` (released
// by the window's thread after its present, vgsdl.retired_release); a
// software picture's image goes once the window has shown the frame that
// runs this.
picture_retire :: proc(ps: ^Pictures, retired: ^vgsdl.Retired, p: Picture) {
	if p.texture != nil {
		vgsdl.retire_texture(ps.device, retired, p.texture)
		return
	}
	if p.key == 0 {
		return
	}
	sync.guard(&ps.mutex)
	append(&ps.ops, Picture_Op{key = p.key, kind = .Free})
}

// The window's thread, before it draws (after taking what the other threads
// published with their pictures, which they wrote first): the software
// pictures' rows queued so far, in order, on canvas `c`.
pictures_run :: proc(ps: ^Pictures, c: ^vg.Canvas) {
	if ps.device != nil {
		return
	}
	sync.mutex_lock(&ps.mutex)
	ps.ops, ps.run_ops = ps.run_ops, ps.ops
	ps.bytes, ps.run_bytes = ps.run_bytes, ps.bytes
	sync.mutex_unlock(&ps.mutex)
	for op in ps.run_ops {
		k := int(op.key) - 1
		switch op.kind {
		case .Make:
			if k >= len(ps.images) do resize(&ps.images, k + 1)
			ps.images[k], _ = vg.create_image_empty(c, op.rect[2], op.rect[3], .RGBA8)
		case .Write:
			w, h := op.rect[2], op.rect[3]
			_ = vg.update_image(c, ps.images[k], vg.image_source_rgba(ps.run_bytes[op.bytes:][:int(w * h * 4)], w, h), op.rect[0], op.rect[1])
		case .Free:
			append(&ps.freeing, op.key)
		}
	}
	clear(&ps.run_ops)
	clear(&ps.run_bytes)
}

// The window's thread, once the frame is shown: the images of the software
// pictures let go of go, and their keys back to the other threads.
pictures_after_frame :: proc(ps: ^Pictures, c: ^vg.Canvas) {
	if len(ps.freeing) == 0 {
		return
	}
	for key in ps.freeing {
		vg.delete_image(c, ps.images[key - 1])
		ps.images[key - 1] = {}
	}
	sync.guard(&ps.mutex)
	append(&ps.free_keys, ..ps.freeing[:])
	clear(&ps.freeing)
}
