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
	// o3d's jobs, one per 3D layer of a frame (in its order), reused frame
	// after frame and freed with the GPU.
	jobs:    [dynamic]^o3d_gpu.Job,
}

view3d_gpu_destroy :: proc(g: ^View3d_Gpu) {
	if g.state == .Ready {
		for job in g.jobs {
			o3d_gpu.job_destroy(&g.gpu, job)
		}
		o3d_gpu.destroy(&g.gpu)
	}
	for job in g.jobs {
		free(job)
	}
	delete(g.jobs)
	g^ = {}
}

// Prepares the frame's jobs (their images in `images`, an SDL_GPU canvas's
// or player's) for the rows that record them (`view3d_job_run`): o3d makes
// and uploads what they draw. The tables stay read-locked until
// `view3d_gpu_done`, after the frame is drawn (`locked`: false when the
// GPU can't render).
view3d_gpu_prepare :: proc(g: ^View3d_Gpu, v: ^View3d_Media, jobs: []^View3d_Job, images: ^vg.Image_Store) -> (err: o3d.Error, locked: bool) {
	switch g.state {
	case .Untried:
		if g.failure = o3d_gpu.init(&g.gpu, g.device); g.failure != nil {
			o3d_gpu.destroy(&g.gpu)
			g.state = .Failed
			return g.failure, false
		}
		g.state = .Ready
	case .Failed:
		return g.failure, false
	case .Ready:
	}
	locked = true
	sync.shared_lock(&v.lock)
	for job, i in jobs {
		if i == len(g.jobs) {
			append(&g.jobs, new(o3d_gpu.Job))
		}
		job.gpu, job.slot, job.media, job.images, job.err = g, i, v, images, nil
		e := o3d_gpu.prepare(&g.gpu, g.jobs[i], &job.scene, &v.geometries, &v.shaders, job.width, job.height, &v.textures)
		job.prepared = e == nil
		if e != nil && err == nil {
			err = e
		}
	}
	return
}

// After the frame the prepared jobs drew in: the tables unlocked, and the
// first error a job's record met.
view3d_gpu_done :: proc(v: ^View3d_Media, jobs: []^View3d_Job) -> (err: o3d.Error) {
	sync.shared_unlock(&v.lock)
	for job in jobs {
		if job.err != nil && err == nil {
			err = job.err
		}
		job.prepared = false
	}
	return
}

// A canvas row's work (vg.run_external): records the job's render into its
// image on the frame's command buffer, its video maps bound to the frames
// made by the rows before it. Once per prepare (a frame drawn again keeps
// what it drew).
view3d_job_run :: proc(user: rawptr, gpu: rawptr) {
	job := (^View3d_Job)(user)
	if gpu == nil || !job.prepared {
		return
	}
	job.prepared = false
	g, v := job.gpu, job.media
	target := vgsdl.image_store_texture(job.images, job.image)
	if target == nil {
		return
	}
	for b in job.videos {
		if frame := vgsdl.image_store_texture(job.images, b.image); frame != nil {
			o3d_gpu.texture_set_external(&g.gpu, &v.textures, b.texture, frame)
		}
	}
	job.err = o3d_gpu.record(&g.gpu, g.jobs[job.slot], target, (^sdl.GPUCommandBuffer)(gpu))
	for b in job.videos {
		o3d_gpu.texture_set_external(&g.gpu, &v.textures, b.texture, nil)
	}
}
