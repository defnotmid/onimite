package render

import "core:mem"
import sdl "vendor:sdl3"

GPU_Release_Queue :: struct {
	buffers:   [dynamic]^sdl.GPUBuffer,
	transfers: [dynamic]^sdl.GPUTransferBuffer,
	textures:  [dynamic]^sdl.GPUTexture,
}

Renderer :: struct {
	device:          ^sdl.GPUDevice,
	window:          ^sdl.Window,
	color_format:    sdl.GPUTextureFormat,
	fb_w, fb_h:      u32,

	// shaders + pipeline cache. SDL3 GPU chooses the backend (Vulkan/Metal)
	// at runtime; we select the matching shader-blob format it reports it accepts.
	shader_format:   sdl.GPUShaderFormat,
	shader_entry_vs: cstring,
	shader_entry_fs: cstring,
	sh_rect_vs:      ^sdl.GPUShader,
	sh_rect_fs:      ^sdl.GPUShader,
	pipe:            ^sdl.GPUGraphicsPipeline,
	sampler:         ^sdl.GPUSampler,
	white_tex:       ^sdl.GPUTexture,

	// per-frame CPU batches
	rect_insts:      [dynamic]Rect_Inst,
	cmds:            [dynamic]Draw_Cmd,

	// streaming GPU buffers (grown on demand; cycled each upload)
	rect_vbo:        ^sdl.GPUBuffer,
	rect_tbo:        ^sdl.GPUTransferBuffer,
	rect_cap:        int,

	// GPU resources cross two release generations. begin_frame moves resources
	// retired before that boundary into releasable_gpu; resources retired after
	// begin_frame remain in retired_gpu because this frame's recorded Draw_Cmds
	// may still contain their handles. end_frame releases only releasable_gpu
	// after the swapchain wait, before replaying the current command list.
	retired_gpu:     GPU_Release_Queue,
	releasable_gpu:  GPU_Release_Queue,

	// draw state
	clip_stack:      [dynamic]sdl.Rect,
	// Fonts with glyphs to upload before this frame replays (font_flush).
	dirty_fonts:     [dynamic]^Font,
	clear_color:     [4]f32,

	// current render-target sub-region applied to every recorded command
	use_viewport:    bool,
	viewport:        sdl.GPUViewport,
	use_scissor:     bool,
	scissor:         sdl.Rect,

	// per-frame GPU handles (valid between begin_frame/end_frame)
	cmd_buf:         ^sdl.GPUCommandBuffer,
	swap_tex:        ^sdl.GPUTexture,
	// Mailbox presents don't wait for vsync: end_frame paces the window at
	// the display's refresh (paced; next_ns the next frame's start).
	paced:           bool,
	next_ns:         u64,
	pass:            ^sdl.GPURenderPass,
	frame_active:    bool,
}

// What failed to set up the UI's drawing.
Error :: enum u8 {
	None,
	// The device takes neither SPIR-V nor MSL.
	Shader_Format,
	Shaders,
	Font,
}

init :: proc(r: ^Renderer, device: ^sdl.GPUDevice, window: ^sdl.Window, fb_w, fb_h: u32) -> Error {
	r.device = device
	r.window = window
	r.color_format = sdl.GetGPUSwapchainTextureFormat(device, window)
	r.fb_w, r.fb_h = fb_w, fb_h
	// Mailbox where the window takes it: the compositor gives back a buffer
	// a newer one replaced, so taking the next image never waits on it. With
	// FIFO it waits for the display, forever when the display is asleep.
	if sdl.WindowSupportsGPUPresentMode(device, window, .MAILBOX) {
		r.paced = sdl.SetGPUSwapchainParameters(device, window, .SDR, .MAILBOX)
	}
	r.retired_gpu = gpu_release_queue_make()
	r.releasable_gpu = gpu_release_queue_make()

	// Pick the shader-blob format accepted by the active backend. The
	// shaders are Slang modules with `vs_main` and `fs_main` entry points:
	// slangc names the SPIR-V entry "main", and keeps the function names
	// for Metal.
	dev := sdl.GetGPUShaderFormats(device)
	switch {
	case .SPIRV in dev:
		r.shader_format, r.shader_entry_vs, r.shader_entry_fs = {.SPIRV}, "main", "main"
	case .MSL in dev:
		r.shader_format, r.shader_entry_vs, r.shader_entry_fs = {.MSL}, "vs_main", "fs_main"
	case:
		return .Shader_Format
	}
	if !_load_shaders(r) {
		return .Shaders
	}
	r.pipe = _build_pipeline(r)

	sampler_info := sdl.GPUSamplerCreateInfo {
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		mipmap_mode    = .NEAREST,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	}
	r.sampler = sdl.CreateGPUSampler(device, sampler_info)

	// 1x1 white texture for solid (untextured) rects.
	r.white_tex = _make_texture(r, 1, 1, .R8G8B8A8_UNORM, {0xff, 0xff, 0xff, 0xff})
	return nil
}

gpu_release_queue_make :: proc() -> GPU_Release_Queue {
	return GPU_Release_Queue {
		buffers = make([dynamic]^sdl.GPUBuffer),
		transfers = make([dynamic]^sdl.GPUTransferBuffer),
		textures = make([dynamic]^sdl.GPUTexture),
	}
}

gpu_release_queue_destroy :: proc(queue: ^GPU_Release_Queue) {
	if queue == nil {
		return
	}
	delete(queue.buffers)
	delete(queue.transfers)
	delete(queue.textures)
	queue^ = {}
}

gpu_release_queue_clear :: proc(queue: ^GPU_Release_Queue) {
	if queue == nil {
		return
	}
	clear(&queue.buffers)
	clear(&queue.transfers)
	clear(&queue.textures)
}

gpu_release_queue_move_all :: proc(dst, src: ^GPU_Release_Queue) {
	if dst == nil || src == nil {
		return
	}
	append(&dst.buffers, ..src.buffers[:])
	append(&dst.transfers, ..src.transfers[:])
	append(&dst.textures, ..src.textures[:])
	gpu_release_queue_clear(src)
}

renderer_advance_gpu_release_generation :: proc(r: ^Renderer) {
	if r == nil {
		return
	}
	gpu_release_queue_move_all(&r.releasable_gpu, &r.retired_gpu)
}

// Queue a buffer for release after in-flight GPU work that may still bind it.
defer_release_buffer :: proc(r: ^Renderer, buffer: ^sdl.GPUBuffer) {
	if r == nil || buffer == nil {
		return
	}
	append(&r.retired_gpu.buffers, buffer)
}

defer_release_transfer_buffer :: proc(r: ^Renderer, buffer: ^sdl.GPUTransferBuffer) {
	if r == nil || buffer == nil {
		return
	}
	append(&r.retired_gpu.transfers, buffer)
}

defer_release_texture :: proc(r: ^Renderer, texture: ^sdl.GPUTexture) {
	if r == nil || texture == nil {
		return
	}
	append(&r.retired_gpu.textures, texture)
}

// Free one release generation after the GPU has finished every submitted frame
// that may have referenced it (swapchain wait or WaitForGPUIdle).
release_gpu_queue :: proc(r: ^Renderer, queue: ^GPU_Release_Queue) {
	if r == nil || r.device == nil || queue == nil {
		return
	}
	for buffer in queue.buffers {
		if buffer != nil {
			sdl.ReleaseGPUBuffer(r.device, buffer)
		}
	}
	for buffer in queue.transfers {
		if buffer != nil {
			sdl.ReleaseGPUTransferBuffer(r.device, buffer)
		}
	}
	for texture in queue.textures {
		if texture != nil {
			sdl.ReleaseGPUTexture(r.device, texture)
		}
	}
	gpu_release_queue_clear(queue)
}

shutdown :: proc(r: ^Renderer) {
	// Drain GPU before any release so deferred and live handles are safe.
	if r.device != nil {
		_ = sdl.WaitForGPUIdle(r.device)
	}
	release_gpu_queue(r, &r.releasable_gpu)
	release_gpu_queue(r, &r.retired_gpu)
	delete(r.dirty_fonts)
	if r.pipe != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.pipe)}
	for sh in ([]^sdl.GPUShader{r.sh_rect_vs, r.sh_rect_fs}) {
		if sh != nil {sdl.ReleaseGPUShader(r.device, sh)}
	}
	if r.white_tex != nil {sdl.ReleaseGPUTexture(r.device, r.white_tex)}
	if r.sampler != nil {sdl.ReleaseGPUSampler(r.device, r.sampler)}
	if r.rect_vbo != nil {sdl.ReleaseGPUBuffer(r.device, r.rect_vbo)}
	if r.rect_tbo != nil {sdl.ReleaseGPUTransferBuffer(r.device, r.rect_tbo)}
	delete(r.rect_insts)
	delete(r.cmds)
	delete(r.clip_stack)
	gpu_release_queue_destroy(&r.releasable_gpu)
	gpu_release_queue_destroy(&r.retired_gpu)
}

resize :: proc(r: ^Renderer, fb_w, fb_h: u32) {
	r.fb_w, r.fb_h = max(fb_w, 1), max(fb_h, 1)
}

_make_texture :: proc(
	r: ^Renderer,
	w, h: u32,
	format: sdl.GPUTextureFormat,
	fill: [4]u8,
) -> ^sdl.GPUTexture {
	tex := sdl.CreateGPUTexture(
		r.device,
		sdl.GPUTextureCreateInfo {
			type = .D2,
			format = format,
			usage = {.SAMPLER},
			width = w,
			height = h,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	// upload the single fill pixel (only used for the 1x1 white texture)
	size := int(w * h * 4)
	tbo := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = u32(size)})
	ptr := cast([^]u8)sdl.MapGPUTransferBuffer(r.device, tbo, false)
	for i in 0 ..< int(
		w * h,
	) {ptr[i * 4 + 0] = fill[0]; ptr[i * 4 + 1] = fill[1]; ptr[i * 4 + 2] = fill[2]; ptr[i * 4 + 3] = fill[3]}
	sdl.UnmapGPUTransferBuffer(r.device, tbo)
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		cp,
		{transfer_buffer = tbo, offset = 0, pixels_per_row = w, rows_per_layer = h},
		{texture = tex, w = w, h = h, d = 1},
		false,
	)
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	defer_release_transfer_buffer(r, tbo)
	return tex
}

// ---- frame ----

begin_frame :: proc(r: ^Renderer, clear_col: [4]f32) -> bool {
	// Only resources retired before this frame are eligible for the wait in this
	// frame's end_frame. Later retirements may still be captured in r.cmds.
	renderer_advance_gpu_release_generation(r)
	clear(&r.rect_insts)
	clear(&r.cmds)
	r.use_viewport = false
	r.use_scissor = false
	clear(&r.clip_stack)
	r.clear_color = clear_col
	r.frame_active = true
	return true
}

end_frame :: proc(r: ^Renderer) {
	font_flush(r)
	r.frame_active = false

	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	r.cmd_buf = cmd

	sw, sh: u32
	// The window's thread never waits on the compositor: a window nobody
	// sees (hidden, minimized, occluded, or on a display that's asleep, which
	// no flag tells) may never get a swapchain image back. No image ready
	// presents nothing this time; the sleep stands in for the vsync wait.
	unseen := sdl.GetWindowFlags(r.window) & {.HIDDEN, .MINIMIZED, .OCCLUDED} != {}
	if !unseen && !sdl.AcquireGPUSwapchainTexture(cmd, r.window, &r.swap_tex, &sw, &sh) {
		r.swap_tex = nil
	}
	if unseen || r.swap_tex == nil {
		if unseen {
			// Even when minimized, prior frame work may have completed; free safe.
			release_gpu_queue(r, &r.releasable_gpu)
		}
		// (No image: frames still in flight may use what's queued; it waits.)
		if unseen || !r.paced {
			sdl.Delay(16 if unseen else 2)
		}
		_ = sdl.SubmitGPUCommandBuffer(cmd)
		pace(r)
		return
	}
	// Previous submitted frames that may have bound mesh/stream buffers are
	// done once the swapchain wait returns (esp. with frames-in-flight = 1).
	release_gpu_queue(r, &r.releasable_gpu)
	if sw != r.fb_w || sh != r.fb_h {resize(r, sw, sh)}

	_record_pass(r, cmd, r.swap_tex)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	r.swap_tex = nil
	pace(r)
}

// A mailbox window's frames a display refresh apart (as FIFO's vsync wait
// spaces them): sleeps to the next frame's start, from the display's mode
// now (the window may have moved displays).
@(private = "file")
pace :: proc(r: ^Renderer) {
	if !r.paced {
		return
	}
	hz: f32 = 60
	if mode := sdl.GetCurrentDisplayMode(sdl.GetDisplayForWindow(r.window)); mode != nil && mode.refresh_rate > 0 {
		hz = mode.refresh_rate
	}
	period := u64(1e9 / hz)
	now := sdl.GetTicksNS()
	if r.next_ns > now {
		sdl.DelayPrecise(r.next_ns - now)
		now = r.next_ns
	}
	r.next_ns += period
	if r.next_ns <= now {
		r.next_ns = now + period // late: start again from now, no burst to catch up
	}
}

// Streams this frame's geometry and replays its commands into `target`.
_record_pass :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, target: ^sdl.GPUTexture) {
	// stream this frame's dynamic geometry (cycled shared transfer buffers)
	_upload_stream(
		r,
		raw_data(r.rect_insts[:]),
		len(r.rect_insts) * size_of(Rect_Inst),
		&r.rect_vbo,
		&r.rect_tbo,
		&r.rect_cap,
		{.VERTEX},
	)
	color := sdl.GPUColorTargetInfo {
		texture     = target,
		load_op     = .CLEAR,
		store_op    = .STORE,
		clear_color = {r.clear_color[0], r.clear_color[1], r.clear_color[2], r.clear_color[3]},
	}
	r.pass = sdl.BeginGPURenderPass(cmd, &color, 1, nil)
	_replay(r)
	sdl.EndGPURenderPass(r.pass)
	r.pass = nil
}

// end_frame_capture finishes the frame into an offscreen texture instead of
// the swapchain and returns it as tightly packed RGBA8 (for smoke tests and
// screenshots without a compositor).
end_frame_capture :: proc(r: ^Renderer, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	font_flush(r)
	r.frame_active = false
	w, h := r.fb_w, r.fb_h
	tex := sdl.CreateGPUTexture(
		r.device,
		{type = .D2, format = r.color_format, usage = {.COLOR_TARGET, .SAMPLER}, width = w, height = h, layer_count_or_depth = 1, num_levels = 1, sample_count = ._1},
	)
	if tex == nil {
		return nil, false
	}
	defer sdl.ReleaseGPUTexture(r.device, tex)
	size := w * h * 4
	tbo := sdl.CreateGPUTransferBuffer(r.device, {usage = .DOWNLOAD, size = size})
	defer sdl.ReleaseGPUTransferBuffer(r.device, tbo)

	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	r.cmd_buf = cmd
	_record_pass(r, cmd, tex)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(cp, {texture = tex, w = w, h = h, d = 1}, {transfer_buffer = tbo, pixels_per_row = w, rows_per_layer = h})
	sdl.EndGPUCopyPass(cp)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		return nil, false
	}
	_ = sdl.WaitForGPUFences(r.device, true, &fence, 1)
	sdl.ReleaseGPUFence(r.device, fence)
	release_gpu_queue(r, &r.releasable_gpu)

	pixels = make([]u8, int(size), allocator)
	mapped := cast([^]u8)sdl.MapGPUTransferBuffer(r.device, tbo, false)
	copy(pixels, mapped[:size])
	sdl.UnmapGPUTransferBuffer(r.device, tbo)
	#partial switch r.color_format {
	case .B8G8R8A8_UNORM, .B8G8R8A8_UNORM_SRGB:
		for i := 0; i < len(pixels); i += 4 {
			pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]
		}
	}
	return pixels, true
}

_upload_stream :: proc(
	r: ^Renderer,
	data: rawptr,
	size: int,
	vbo: ^^sdl.GPUBuffer,
	tbo: ^^sdl.GPUTransferBuffer,
	cap: ^int,
	usage: sdl.GPUBufferUsageFlags,
) {
	if size == 0 {return}
	if size > cap^ {
		newcap := max(size, cap^ * 2, 4096)
		if vbo^ != nil {
			defer_release_buffer(r, vbo^)
			vbo^ = nil
		}
		if tbo^ != nil {
			defer_release_transfer_buffer(r, tbo^)
			tbo^ = nil
		}
		vbo^ = sdl.CreateGPUBuffer(r.device, {usage = usage, size = u32(newcap)})
		tbo^ = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = u32(newcap)})
		cap^ = newcap
	}
	ptr := sdl.MapGPUTransferBuffer(r.device, tbo^, true) // cycle
	mem.copy(ptr, data, size)
	sdl.UnmapGPUTransferBuffer(r.device, tbo^)
	cp := sdl.BeginGPUCopyPass(r.cmd_buf)
	sdl.UploadToGPUBuffer(
		cp,
		{transfer_buffer = tbo^, offset = 0},
		{buffer = vbo^, offset = 0, size = u32(size)},
		true,
	)
	sdl.EndGPUCopyPass(cp)
}

_replay :: proc(r: ^Renderer) {
	full_vp := sdl.GPUViewport{0, 0, f32(r.fb_w), f32(r.fb_h), 0, 1}
	full_sc := sdl.Rect{0, 0, i32(r.fb_w), i32(r.fb_h)}
	if r.pipe == nil {
		return
	}
	sdl.BindGPUGraphicsPipeline(r.pass, r.pipe)
	for &cmd in r.cmds {
		vp := cmd.use_viewport ? cmd.viewport : full_vp
		sc := cmd.use_scissor ? cmd.scissor : full_sc
		sdl.SetGPUViewport(r.pass, vp)
		sdl.SetGPUScissor(r.pass, sc)
		ru := cmd.rect_u
		sdl.PushGPUVertexUniformData(r.cmd_buf, 0, &ru, size_of(ru))
		tex := cmd.tex != nil ? cmd.tex : r.white_tex
		tsb := sdl.GPUTextureSamplerBinding {
			texture = tex,
			sampler = r.sampler,
		}
		sdl.BindGPUFragmentSamplers(r.pass, 0, &tsb, 1)
		b := sdl.GPUBufferBinding {
			buffer = r.rect_vbo,
			offset = 0,
		}
		sdl.BindGPUVertexBuffers(r.pass, 0, &b, 1)
		sdl.DrawGPUPrimitives(r.pass, 4, cmd.count, 0, cmd.first)
	}
}

// Stamp the current viewport/scissor sub-region onto a command being recorded.
_fill_target :: proc(r: ^Renderer, cmd: ^Draw_Cmd) {
	cmd.use_viewport = r.use_viewport
	cmd.viewport = r.viewport
	cmd.use_scissor = r.use_scissor
	cmd.scissor = r.scissor
}
