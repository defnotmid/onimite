package onimite_encode

import "core:log"
import "core:mem"
import "core:testing"
import sdl "vendor:sdl3"

// The compute pass (SPIR-V on Vulkan, MSL on Metal) gives the same planes as
// the CPU conversion. Skipped without an SDL_GPU device, which includes
// macOS: tests run off the main thread, where Cocoa (needed by SDL's Metal
// driver) won't start.
@(test)
test_gpu_nv12_matches_cpu :: proc(t: ^testing.T) {
	// Odd widths exercise the luma row padding (y_stride rounds up to 8).
	W :: 70
	H :: 46
	if !sdl.Init({.VIDEO}) {
		sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen")
		if !sdl.Init({.VIDEO}) {
			log.info("no SDL video: skipped")
			return
		}
	}
	defer sdl.Quit()
	device := sdl.CreateGPUDevice({.SPIRV, .MSL}, false, nil)
	if device == nil {
		log.infof("no SDL_GPU device (%s): skipped", sdl.GetError())
		return
	}
	defer sdl.DestroyGPUDevice(device)

	g: GPU_NV12
	if !testing.expect_value(t, gpu_nv12_init(&g, device, W, H), Error.None) {
		return
	}
	defer gpu_nv12_destroy(&g)

	rgba := make([]u8, W * H * 4, context.temp_allocator)
	seed: u32 = 12345
	for &b, i in rgba {
		seed = seed * 1664525 + 1013904223
		b = 255 if i % 4 == 3 else u8(seed >> 24)
	}
	transfer := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = u32(len(rgba))})
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)
	mem.copy(sdl.MapGPUTransferBuffer(device, transfer, false), raw_data(rgba), len(rgba))
	sdl.UnmapGPUTransferBuffer(device, transfer)
	cmd := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(pass, {transfer_buffer = transfer, pixels_per_row = W, rows_per_layer = H}, {texture = gpu_nv12_target(&g), w = W, h = H, d = 1}, false)
	sdl.EndGPUCopyPass(pass)
	testing.expect(t, sdl.SubmitGPUCommandBuffer(cmd))

	testing.expect_value(t, gpu_nv12_submit(&g, 7), Error.None)
	data, frame, _ := gpu_nv12_wait(&g)
	defer gpu_nv12_release(&g)
	testing.expect_value(t, frame, 7)
	if !testing.expect(t, data != nil, "map") {
		return
	}

	want := make([]u8, W * H * 3 / 2, context.temp_allocator)
	rgba_to_i420(rgba, W, H, want)
	// The GPU's Y and interleaved UV against the CPU's Y, U and V planes.
	cw, ch := W / 2, H / 2
	planes := [3]struct {
		w, h, stride, step, src, dst: int,
	}{{W, H, g.y_stride, 1, 0, 0}, {cw, ch, g.y_stride, 2, g.y_stride * H, W * H}, {cw, ch, g.y_stride, 2, g.y_stride * H + 1, W * H + cw * ch}}
	mismatches := 0
	for p, pi in planes {
		for y in 0 ..< p.h {
			for x in 0 ..< p.w {
				got, exp := data[p.src + y * p.stride + x * p.step], want[p.dst + y * p.w + x]
				if got != exp {
					if mismatches < 5 {
						log.errorf("plane %d (%d,%d): gpu %d, cpu %d", pi, x, y, got, exp)
					}
					mismatches += 1
				}
			}
		}
	}
	testing.expect_value(t, mismatches, 0)
}
