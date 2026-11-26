package platform

import sdl "vendor:sdl3"

// The SDL_GPU device onimite draws with, the window's and a render's:
// Vulkan (SPIR-V) or Metal (MSL), and Direct3D 12 (DXBC) only where neither
// opens and the adapter is hardware. SDL tries Direct3D 12 before Vulkan,
// so DXBC is asked for only when SDL finds no driver for SPIR-V and MSL:
// Windows takes Direct3D 12 where no Vulkan driver is installed (or with
// SDL_GPU_DRIVER=direct3d12). A machine whose only adapter is Microsoft's
// software rasterizer (WARP) gets no device, and onimite draws on the CPU,
// several times faster than WARP. Nil when no device opens (SDL_GetError
// says why); SDL's video subsystem must be up.
gpu_device_create :: proc(debug: bool) -> ^sdl.GPUDevice {
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true)
	_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true)
	_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, debug)
	if !sdl.GPUSupportsProperties(props) && d3d12_on_hardware() {
		_ = sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_DXBC_BOOLEAN, true)
	}
	return sdl.CreateGPUDeviceWithProperties(props)
}

// A device for drawing without a window, without SDL's validation: SDL's
// video subsystem started if nothing started it, on its offscreen driver
// where no display is (macOS's Metal needs its usual driver).
gpu_device_headless :: proc() -> ^sdl.GPUDevice {
	if .VIDEO not_in sdl.WasInit({.VIDEO}) && !sdl.Init({.VIDEO}) {
		sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen")
		if !sdl.Init({.VIDEO}) {
			return nil
		}
	}
	return gpu_device_create(false)
}
