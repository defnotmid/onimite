package onimite_encode

import movie "deps:odecs/movie"
import sdl "vendor:sdl3"

// Converts GPU-rendered frames to NV12 on the GPU (shaders/rgba_to_nv12.slang)
// and reads them back pipelined: `submit` records the conversion and the
// download after the frame's render and returns; `feed` hands the downloads
// that are done to the encoder as they are mapped (the encoder reads them
// there: no copy), and `reserve` frees the oldest slot once the encoder is
// done with it. With GPU_NV12_SLOTS frames in flight the render loop records
// frame N+1 while earlier ones convert, transfer and encode, and it reads
// back 1.5 bytes a pixel instead of 4. The samples are bit-identical to the
// CPU path's (odecs' rgba_to_i420 with the same coefficients).
//
// Each slot has its own RGBA target to render the frame into
// (`gpu_nv12_target`) and its own output buffer: with shared ones, the next
// frame could overwrite them while the previous conversion or download still
// used them. The pass reads the target as a storage texture, so SDL_GPU
// orders it after the render (its sampler barriers leave compute out).
//
//     g: GPU_NV12
//     gpu_nv12_init(&g, device, w, h)
//     for f in frames {
//         gpu_nv12_reserve(&g, &e)
//         render(f) // into gpu_nv12_target(&g)
//         gpu_nv12_submit(&g, f)
//         gpu_nv12_feed(&g, &e, wait = false)
//     }
//     gpu_nv12_finish(&g, &e)

// Frames between render and encoder: converting, downloading, or queued in
// the encoder's ring (which reads them in place).
GPU_NV12_SLOTS :: 6

GPU_NV12 :: struct {
	device:   ^sdl.GPUDevice,
	pipeline: ^sdl.GPUComputePipeline,
	slots:    [GPU_NV12_SLOTS]GPU_NV12_Slot,
	head:     int, // oldest frame in flight
	count:    int,
	// Of the `count` from `head`, those handed to the encoder.
	handed:   int,
	width:    int,
	height:   int,
	// Luma bytes per row (a multiple of 8); chroma rows are half of it.
	y_stride: int,
	size:     int,
	params:   GPU_NV12_Params,
}

@(private)
GPU_NV12_Slot :: struct {
	target:   ^sdl.GPUTexture,
	// The conversion output, downloaded into `transfer`. Per slot: a shared
	// one could be overwritten by the next frame's pass before its download
	// ran (seen under load).
	buffer:   ^sdl.GPUBuffer,
	transfer: ^sdl.GPUTransferBuffer,
	fence:    ^sdl.GPUFence,
	frame:    int,
	mapped:   bool,
	// The encoder's number for the frame once handed to it (`write_nv12`).
	queued:   i64,
}

// Matches `Params` in rgba_to_nv12.slang.
@(private)
GPU_NV12_Params :: struct {
	ky, ku, kv: [4]i32,
	size:       [4]u32,
}

@(private)
RGBA_TO_NV12_SPV :: #load("../shaders/rgba_to_nv12.comp.spv")
@(private)
RGBA_TO_NV12_MSL :: #load("../shaders/rgba_to_nv12.comp.msl")

// `.Gpu_Unsupported` when the device can't run the pass (the caller reads
// RGBA back and converts on the CPU instead). Sizes must be even, as for
// `open`.
gpu_nv12_init :: proc(g: ^GPU_NV12, device: ^sdl.GPUDevice, width, height: int) -> Error {
	g^ = {device = device, width = width, height = height}
	g.y_stride = (width + 7) &~ 7
	g.size = g.y_stride * height * 3 / 2

	formats := sdl.GetGPUShaderFormats(device)
	code: []u8
	format: sdl.GPUShaderFormat
	entry: cstring
	switch {
	case .SPIRV in formats:
		code, format, entry = RGBA_TO_NV12_SPV, {.SPIRV}, "main"
	case .MSL in formats:
		code, format, entry = RGBA_TO_NV12_MSL, {.MSL}, "cs_main"
	case:
		return .Gpu_Unsupported
	}
	g.pipeline = sdl.CreateGPUComputePipeline(
		device,
		{
			code_size = len(code),
			code = raw_data(code),
			entrypoint = entry,
			format = format,
			num_readonly_storage_textures = 1,
			num_readwrite_storage_buffers = 1,
			num_uniform_buffers = 1,
			threadcount_x = 8,
			threadcount_y = 8,
			threadcount_z = 1,
		},
	)
	ok := g.pipeline != nil
	for &s in g.slots {
		s.buffer = sdl.CreateGPUBuffer(device, {usage = {.COMPUTE_STORAGE_WRITE}, size = u32(g.size)})
		s.transfer = sdl.CreateGPUTransferBuffer(device, {usage = .DOWNLOAD, size = u32(g.size)})
		s.target = sdl.CreateGPUTexture(device, {type = .D2, format = .R8G8B8A8_UNORM, usage = {.COLOR_TARGET, .COMPUTE_STORAGE_READ}, width = u32(width), height = u32(height), layer_count_or_depth = 1, num_levels = 1})
		ok &&= s.transfer != nil && s.target != nil && s.buffer != nil
	}
	if !ok {
		gpu_nv12_destroy(g)
		return .Gpu_Unsupported
	}

	c := movie.rgb_to_yuv_coefficients(.BT709, false)
	uv_offset := g.y_stride * height
	g.params = {
		ky = {c.y[0], c.y[1], c.y[2], c.y_bias},
		ku = {c.u[0], c.u[1], c.u[2], c.c_bias},
		kv = {c.v[0], c.v[1], c.v[2], c.c_max},
		size = {u32(width), u32(height), u32(g.y_stride), u32(uv_offset)},
	}
	return nil
}

gpu_nv12_destroy :: proc(g: ^GPU_NV12) {
	if g.device == nil {
		return
	}
	for g.count > 0 {
		_, _, _ = gpu_nv12_wait(g)
		gpu_nv12_release(g)
	}
	for s in g.slots {
		if s.transfer != nil {sdl.ReleaseGPUTransferBuffer(g.device, s.transfer)}
		if s.target != nil {sdl.ReleaseGPUTexture(g.device, s.target)}
		if s.buffer != nil {sdl.ReleaseGPUBuffer(g.device, s.buffer)}
	}
	if g.pipeline != nil {sdl.ReleaseGPUComputePipeline(g.device, g.pipeline)}
	g^ = {}
}

// The texture to render the next frame into (RGBA8, the size given to
// init): the next slot's, free after `gpu_nv12_reserve`.
gpu_nv12_target :: proc(g: ^GPU_NV12) -> ^sdl.GPUTexture {
	return g.slots[(g.head + g.count) % GPU_NV12_SLOTS].target
}

// Records the conversion of the frame rendered into `gpu_nv12_target` and
// its download. Needs a free slot (`gpu_nv12_reserve`).
gpu_nv12_submit :: proc(g: ^GPU_NV12, frame: int) -> Error {
	assert(g.count < GPU_NV12_SLOTS)
	s := &g.slots[(g.head + g.count) % GPU_NV12_SLOTS]
	cmd := sdl.AcquireGPUCommandBuffer(g.device)
	if cmd == nil {
		return .Gpu_Submit
	}
	sdl.PushGPUComputeUniformData(cmd, 0, &g.params, size_of(g.params))
	storage := sdl.GPUStorageBufferReadWriteBinding{buffer = s.buffer}
	pass := sdl.BeginGPUComputePass(cmd, nil, 0, &storage, 1)
	sdl.BindGPUComputePipeline(pass, g.pipeline)
	sdl.BindGPUComputeStorageTextures(pass, 0, &s.target, 1)
	sdl.DispatchGPUCompute(pass, u32(g.y_stride / 8 + 7) / 8, u32(g.height / 2 + 7) / 8, 1)
	sdl.EndGPUComputePass(pass)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUBuffer(copy_pass, {buffer = s.buffer, size = u32(g.size)}, {transfer_buffer = s.transfer})
	sdl.EndGPUCopyPass(copy_pass)
	s.fence = sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if s.fence == nil {
		return .Gpu_Submit
	}
	s.frame = frame
	g.count += 1
	return nil
}

// Waits for the oldest frame in flight and maps its planes: Y, then
// interleaved U and V, both `y_stride` bytes per row. Valid until
// `gpu_nv12_release`.
gpu_nv12_wait :: proc(g: ^GPU_NV12) -> (data: []u8, frame: int, err: Error) {
	assert(g.count > 0)
	s := &g.slots[g.head]
	data, err = slot_map(g, s)
	return data, s.frame, err
}

// Unmaps the oldest frame and frees its slot.
gpu_nv12_release :: proc(g: ^GPU_NV12) {
	assert(g.count > 0)
	s := &g.slots[g.head]
	if s.mapped {
		sdl.UnmapGPUTransferBuffer(g.device, s.transfer)
		s.mapped = false
	}
	g.head = (g.head + 1) % GPU_NV12_SLOTS
	g.count -= 1
	g.handed = max(g.handed - 1, 0)
}

// Hands the converted frames not handed yet to the encoder, oldest first,
// as their mapped bytes: those whose download is done, and with `wait` at
// least the oldest.
gpu_nv12_feed :: proc(g: ^GPU_NV12, e: ^Encoder, wait: bool) -> Error {
	must := wait
	for g.handed < g.count {
		s := &g.slots[(g.head + g.handed) % GPU_NV12_SLOTS]
		if !must && s.fence != nil && !sdl.QueryGPUFence(g.device, s.fence) {
			break
		}
		must = false
		data := slot_map(g, s) or_return
		s.queued = write_nv12(e, data, g.y_stride) or_return
		g.handed += 1
	}
	return nil
}

// Frees the oldest slot when every one is in use, once the encoder is done
// with its frame (handed to it first if it wasn't).
gpu_nv12_reserve :: proc(g: ^GPU_NV12, e: ^Encoder) -> Error {
	if g.count < GPU_NV12_SLOTS {
		return nil
	}
	return free_oldest(g, e)
}

// Hands every frame left to the encoder and frees the slots as it finishes
// them.
gpu_nv12_finish :: proc(g: ^GPU_NV12, e: ^Encoder) -> Error {
	for g.count > 0 {
		free_oldest(g, e) or_return
	}
	return nil
}

@(private = "file")
free_oldest :: proc(g: ^GPU_NV12, e: ^Encoder) -> Error {
	if g.handed == 0 {
		gpu_nv12_feed(g, e, wait = true) or_return
	}
	wait_frame(e, g.slots[g.head].queued) or_return
	gpu_nv12_release(g)
	return nil
}

// Waits for the slot's download and maps it.
@(private = "file")
slot_map :: proc(g: ^GPU_NV12, s: ^GPU_NV12_Slot) -> ([]u8, Error) {
	if s.fence != nil {
		_ = sdl.WaitForGPUFences(g.device, true, &s.fence, 1)
		sdl.ReleaseGPUFence(g.device, s.fence)
		s.fence = nil
	}
	p := ([^]u8)(sdl.MapGPUTransferBuffer(g.device, s.transfer, false))
	if p == nil {
		return nil, .Gpu_Map
	}
	s.mapped = true
	return p[:g.size], nil
}
