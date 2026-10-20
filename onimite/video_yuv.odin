package onimite

import "core:math"
import oksl "deps:oksl"
import vg "deps:ovg"

// Clip frames arrive as the decoder's planes (`Video_Frame.planes`). GPU
// renders upload them to single-channel images and convert them into the
// slot's RGBA image with one program (video_yuv.sksl, odecs' conversion),
// recorded with the frame, so the conversion runs where the frame is drawn
// and reads the planes uploaded when it plays. Software renders convert on
// the CPU (`Video_Source.to_rgba`).

@(private = "file")
VIDEO_YUV_SKSL :: #load("video_yuv.sksl", string)

// The conversion program of a renderer, compiled on first use.
@(private)
Yuv_Program :: struct {
	module:  ^oksl.Module,
	program: vg.Program_Id,
	cpu:     ^Shader_Cpu,
	failed:  bool,
}

@(private)
yuv_program_destroy :: proc(p: ^Yuv_Program, c: ^vg.Canvas) {
	if vg.program_id_valid(p.program) {
		vg.delete_program(c, p.program)
	}
	if p.module != nil {
		oksl.destroy(p.module)
	}
	free(p.cpu)
	p^ = {}
}

// The size of plane `i` (Y', Cb, Cr, alpha) of a `width x height` frame in
// format `f`; 0 x 0 when the frame has no such plane.
video_plane_size :: proc(f: Video_Format, width, height, i: int) -> (w, h: int) {
	switch i {
	case 0:
		return width, height
	case 1, 2:
		if f.monochrome {
			return 0, 0
		}
		return (width + 1 << uint(f.shift_x) - 1) >> uint(f.shift_x), (height + 1 << uint(f.shift_y) - 1) >> uint(f.shift_y)
	case 3:
		if !f.alpha {
			return 0, 0
		}
		return width, height
	}
	return 0, 0
}

// Whether clip frames convert on the GPU: the renderer draws there, or its
// records play there.
@(private)
video_on_gpu :: proc(r: ^Renderer) -> bool {
	return r.plays_on_gpu if r.recording else !r.is_software
}

// Makes slot `slot`'s plane images for `info`'s frames (kept while the
// slot's size stays).
@(private)
video_slot_planes :: proc(r: ^Renderer, slot: int, info: Video_Info) -> bool {
	planes := &r.video_images.planes[slot]
	if vg.image_id_valid(planes[0]) {
		return true
	}
	format: vg.Pixel_Format = .Gray16 if info.format.wide else .Gray8
	for i in 0 ..< 4 {
		w, h := video_plane_size(info.format, info.width, info.height, i)
		if w == 0 {
			continue
		}
		id, err := vg.create_image_empty(&r.canvas, u32(w), u32(h), format, {.Nearest})
		if err != nil {
			report(&r.ctx, .Error, {code = .Video_Frame_Image, gpu = err})
			video_slot_planes_free(r, slot)
			return false
		}
		planes[i] = id
	}
	return true
}

@(private)
video_slot_planes_free :: proc(r: ^Renderer, slot: int) {
	for &id in r.video_images.planes[slot] {
		if vg.image_id_valid(id) {
			vg.delete_image(&r.canvas, id)
		}
		id = {}
	}
}

// The frame's planes as single-channel image sources (Gray16 for deep
// samples); none for planes the frame lacks.
@(private)
video_plane_sources :: proc(f: Video_Frame) -> (sources: [4]vg.Image_Source) {
	for i in 0 ..< 4 {
		w, h := video_plane_size(f.format, f.width, f.height, i)
		if w == 0 {
			continue
		}
		if f.format.wide {
			sources[i] = vg.image_source_gray16(f.planes[i], u32(w), u32(h))
		} else {
			sources[i] = vg.image_source_gray(f.planes[i], u32(w), u32(h))
		}
	}
	return
}

// Records the conversion of slot `slot`'s planes into its image.
@(private)
video_yuv_run :: proc(r: ^Renderer, slot: int, info: Video_Info) -> bool {
	y := &r.video_images.yuv
	if y.module == nil {
		if y.failed {
			return false
		}
		m, _, ok := oksl.compile(VIDEO_YUV_SKSL)
		y.module = m
		if !ok {
			y.failed = true
			return false
		}
		prog, err := shader_register(r, m, &y.cpu)
		if err != nil {
			y.failed = true
			report(&r.ctx, .Error, {code = .Video_Frame_Image, gpu = err})
			return false
		}
		y.program = prog
	}
	m := y.module
	block := make([]u8, m.block_size, context.temp_allocator)
	oksl.write_input(block, .Resolution, {f32(info.width), f32(info.height), 1})
	planes := r.video_images.planes[slot]
	for i in 0 ..< 4 {
		w, h := video_plane_size(info.format, info.width, info.height, i)
		oksl.write_input(block, .Channel_Resolution, {f32(max(w, 1)), f32(max(h, 1)), 1}, i)
	}
	u := yuv_uniforms(info.format)
	oksl.set_uniform(m, block, "sampling", u.sampling[:])
	oksl.set_uniform(m, block, "ranges", u.ranges[:])
	oksl.set_uniform(m, block, "coefs", u.coefs[:])
	oksl.set_uniform(m, block, "mode", u.mode[:])
	oksl.set_uniform(m, block, "alpha_mode", u.alpha_mode[:])
	oksl.set_uniform(m, block, "tone_curve", u.tone_curve[:])
	oksl.set_uniform(m, block, "gamut_r", u.gamut[0][:])
	oksl.set_uniform(m, block, "gamut_g", u.gamut[1][:])
	oksl.set_uniform(m, block, "gamut_b", u.gamut[2][:])
	if err := vg.run_program(&r.canvas, y.program, r.video_images.image[slot], block, planes[:]); err != nil {
		report(&r.ctx, .Error, {code = .Video_Frame_Image, gpu = err})
		return false
	}
	return true
}

// video_yuv.sksl's uniforms for frames in format `f`: odecs' choices
// (video/planar.odin `prepare_conversion`, hdr.odin `init_tone_map`).
@(private = "file")
Yuv_Uniforms :: struct {
	sampling, ranges, coefs, mode, alpha_mode, tone_curve: [4]f32,
	gamut: [3][3]f32,
}

@(private = "file")
yuv_uniforms :: proc(f: Video_Format) -> (u: Yuv_Uniforms) {
	depth := max(f.bit_depth, 8)
	full := f32(int(1) << uint(depth) - 1)
	scale := f32(int(1) << uint(depth - 8))
	u.sampling = {65535 if f.wide else 255, f32(int(1) << uint(f.shift_x)), f32(int(1) << uint(f.shift_y)), 1 / full}
	kr, kb: f32 = 0.2126, 0.0722
	switch f.matrix_coeffs {
	case 5, 6:
		kr, kb = 0.299, 0.114
	case 9, 10:
		kr, kb = 0.2627, 0.0593
	}
	kg := 1 - kr - kb
	u.coefs = {2 * (1 - kr), -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 2 * (1 - kb)}
	gbr := f.matrix_coeffs == 0 && !f.monochrome && f.shift_x == 0 && f.shift_y == 0
	hdr := f.transfer == 16 || f.transfer == 18 || f.primaries == 9
	path: f32 = 1 if gbr else 2 if hdr else 0
	if hdr {
		if f.full_range {
			u.ranges = {1 / full, 0, 1 / full, f32(int(1) << uint(depth - 1)) / full}
		} else {
			u.ranges = {1 / (219 * scale), 16.0 / 219, 1 / (224 * scale), 128.0 / 224}
		}
	} else {
		ys := (255 if f.full_range else 219) * scale
		cs := (255 if f.full_range else 224) * scale
		u.ranges = {1 / ys, (0 if f.full_range else 16 * scale) / ys, 1 / cs, 128 * scale / cs}
	}
	transfer: f32 = 1 if f.transfer == 16 else 2 if f.transfer == 18 else 0
	u.mode = {path, transfer, 1 if f.monochrome else 0, 1 if f.primaries == 9 else 0}
	SDR_WHITE :: 203.0
	HDR_PEAK :: 1000.0
	u.alpha_mode = {1 if f.alpha else 0, 1 if f.alpha_premultiplied else 0, HDR_PEAK / SDR_WHITE, 0}
	source := pq_inverse(HDR_PEAK)
	max_lum := pq_inverse(SDR_WHITE) / source
	u.tone_curve = {f32(source), f32(1.5 * max_lum - 0.5), f32(max_lum), 0}
	// Linear BT.2020 to BT.709 (from the primaries and D65, BT.2087).
	u.gamut = {{1.6604910, -0.5876411, -0.0728499}, {-0.1245505, 1.1328999, -0.0083494}, {-0.0181508, -0.1005789, 1.1187297}}
	return
}

// SMPTE ST 2084: nits to signal.
@(private = "file")
pq_inverse :: proc(nits: f64) -> f64 {
	M1 :: 2610.0 / 16384
	M2 :: 2523.0 / 4096 * 128
	C1 :: 3424.0 / 4096
	C2 :: 2413.0 / 4096 * 32
	C3 :: 2392.0 / 4096 * 32
	y := math.pow(nits / 10000, M1)
	return math.pow((C1 + C2 * y) / (1 + C3 * y), M2)
}
