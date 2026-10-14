package onimite

import "core:sync"
import "deps:o3d"
import o3d_gpu "deps:o3d/sdlgpu"
import vg "deps:ovg"
import vgsdl "deps:ovg/sdlgpu"
import sdl "vendor:sdl3"

// The GPU 3D layers render on: o3d's SDL_GPU renderer on a borrowed device,
// set up the first time a frame has a 3D layer. One per device owner (the
// app, the preview's worker), used on its thread only. It mirrors whichever
// media's tables a job draws from: handed another media's (a reload), o3d
// starts its mirror over.
View3d_Gpu :: struct {
	device:  ^sdl.GPUDevice,
	gpu:     o3d_gpu.GPU,
	state:   enum u8 {
		Untried,
		Ready,
		Failed,
	},
	// Why setting it up failed.
	failure: o3d.Error,
}

view3d_gpu_destroy :: proc(g: ^View3d_Gpu) {
	if g.state == .Ready {
		o3d_gpu.destroy(&g.gpu)
	}
	g^ = {}
}

// Renders the jobs into their images, which belong to `images` (an SDL_GPU
// canvas's or player's), in one command buffer. It is submitted before the
// frame showing them is (SDL_GPU runs submissions in order).
view3d_gpu_render :: proc(g: ^View3d_Gpu, v: ^View3d_Media, jobs: []View3d_Job, images: ^vg.Image_Store) -> (err: o3d.Error) {
	switch g.state {
	case .Untried:
		if g.failure = o3d_gpu.init(&g.gpu, g.device); g.failure != nil {
			o3d_gpu.destroy(&g.gpu)
			g.state = .Failed
			return g.failure
		}
		g.state = .Ready
	case .Failed:
		return g.failure
	case .Ready:
	}
	cmd := sdl.AcquireGPUCommandBuffer(g.device)
	if cmd == nil {
		return .Device
	}
	sync.shared_guard(&v.lock)
	for &job in jobs {
		entry := vg.image_store_get(images, job.image)
		if entry == nil || entry.image.user == nil {
			continue
		}
		target := (^vgsdl.Image)(entry.image.user).texture
		if e := o3d_gpu.render(&g.gpu, &job.scene, &v.geometries, &v.shaders, target, job.width, job.height, cmd, &v.textures); e != nil && err == nil {
			err = e
		}
	}
	if !sdl.SubmitGPUCommandBuffer(cmd) && err == nil {
		err = .Device
	}
	return
}
