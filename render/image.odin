package render

import "core:mem"
import sdl "vendor:sdl3"

Image :: struct {
	texture:       ^sdl.GPUTexture,
	width, height: u32,
}

image_loaded :: proc(image: ^Image) -> bool {
	return image != nil && image.texture != nil && image.width > 0 && image.height > 0
}

// texture_upload fills an RGBA8 texture from tightly packed pixels.
texture_upload :: proc(r: ^Renderer, texture: ^sdl.GPUTexture, width, height: u32, pixels: []u8) -> bool {
	if r == nil || texture == nil || width == 0 || height == 0 || len(pixels) < int(width * height * 4) {
		return false
	}
	size := width * height * 4
	transfer := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = size})
	if transfer == nil {
		return false
	}
	mapped := sdl.MapGPUTransferBuffer(r.device, transfer, false)
	if mapped == nil {
		sdl.ReleaseGPUTransferBuffer(r.device, transfer)
		return false
	}
	mem.copy(mapped, raw_data(pixels), int(size))
	sdl.UnmapGPUTransferBuffer(r.device, transfer)

	command := sdl.AcquireGPUCommandBuffer(r.device)
	copy_pass := sdl.BeginGPUCopyPass(command)
	sdl.UploadToGPUTexture(
		copy_pass,
		{transfer_buffer = transfer, offset = 0, pixels_per_row = width, rows_per_layer = height},
		{texture = texture, w = width, h = height, d = 1},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)
	// SDL frees the transfer buffer once the upload is done.
	defer sdl.ReleaseGPUTransferBuffer(r.device, transfer)
	return sdl.SubmitGPUCommandBuffer(command)
}

// image_texture_make makes a sampled RGBA8 texture holding `pixels`.
image_texture_make :: proc(r: ^Renderer, width, height: u32, pixels: []u8) -> Image {
	if r == nil || width == 0 || height == 0 {
		return {}
	}
	texture := sdl.CreateGPUTexture(
		r.device,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = width,
			height = height,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	if texture == nil || !texture_upload(r, texture, width, height, pixels) {
		if texture != nil {
			sdl.ReleaseGPUTexture(r.device, texture)
		}
		return {}
	}
	return {texture = texture, width = width, height = height}
}

image_destroy :: proc(r: ^Renderer, image: ^Image) {
	if r != nil && image.texture != nil {
		defer_release_texture(r, image.texture)
	}
	image^ = {}
}
