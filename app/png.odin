package onimite_app

import "core:os"
import odimg "deps:odecs/image"

// Straight-alpha RGBA8 pixels of a PNG (or any image odecs reads).
read_png :: proc(path: string) -> (pixels: []u8, w, h: u32, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, 0, 0, false
	}
	img, derr := odimg.decode(data, allocator = context.temp_allocator)
	if derr != .None {
		return nil, 0, 0, false
	}
	return img.pixels, u32(img.width), u32(img.height), true
}
