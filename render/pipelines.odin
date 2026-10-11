package render

import sdl "vendor:sdl3"

// Shader bytecode is per-backend (the one thing SDL_GPU does not cross-compile):
// SPIR-V (Vulkan) and MSL (Metal), committed beside their Slang sources.

RECT_VS_SPV := #load("../shaders/rect2d.vert.spv")
RECT_VS_MSL := #load("../shaders/rect2d.vert.msl")
RECT_FS_SPV := #load("../shaders/rect2d.frag.spv")
RECT_FS_MSL := #load("../shaders/rect2d.frag.msl")

_create_shader :: proc(r: ^Renderer, spirv, msl: []u8, stage: sdl.GPUShaderStage, num_uniform, num_sampler: u32) -> ^sdl.GPUShader {
	code := msl if .MSL in r.shader_format else spirv
	info := sdl.GPUShaderCreateInfo {
		code_size           = len(code),
		code                = raw_data(code),
		entrypoint          = stage == .VERTEX ? r.shader_entry_vs : r.shader_entry_fs,
		format              = r.shader_format,
		stage               = stage,
		num_uniform_buffers = num_uniform,
		num_samplers        = num_sampler,
	}
	return sdl.CreateGPUShader(r.device, info)
}

_load_shaders :: proc(r: ^Renderer) -> bool {
	r.sh_rect_vs = _create_shader(r, RECT_VS_SPV, RECT_VS_MSL, .VERTEX, 1, 0)
	r.sh_rect_fs = _create_shader(r, RECT_FS_SPV, RECT_FS_MSL, .FRAGMENT, 0, 1)
	return r.sh_rect_vs != nil && r.sh_rect_fs != nil
}

_straight_alpha_blend :: sdl.GPUColorTargetBlendState {
	enable_blend          = true,
	src_color_blendfactor = .SRC_ALPHA,
	dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
	color_blend_op        = .ADD,
	src_alpha_blendfactor = .ONE,
	dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
	alpha_blend_op        = .ADD,
}

// Builds the instanced rounded-rect pipeline: one instance per Rect_Inst,
// drawn as a 4-vertex triangle strip.
_build_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	if r.sh_rect_vs == nil || r.sh_rect_fs == nil {
		return nil
	}
	buffers := [1]sdl.GPUVertexBufferDescription{{slot = 0, pitch = size_of(Rect_Inst), input_rate = .INSTANCE}}
	attrs: [8]sdl.GPUVertexAttribute
	for i in 0 ..< u32(8) {
		attrs[i] = {
			location    = i,
			buffer_slot = 0,
			format      = .FLOAT4,
			offset      = i * 16,
		}
	}
	color_target := sdl.GPUColorTargetDescription {
		format      = r.color_format,
		blend_state = _straight_alpha_blend,
	}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = r.sh_rect_vs,
		fragment_shader = r.sh_rect_fs,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = len(attrs),
		},
		primitive_type = .TRIANGLESTRIP,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE},
		target_info = {color_target_descriptions = &color_target, num_color_targets = 1},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
