package onimite_app

import "core:strings"
import stbi "vendor:stb/image"

// Straight-alpha RGBA8 pixels of a PNG (or any stb_image format).
read_png :: proc(path: string) -> (pixels: []u8, w, h: u32, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	x, y, ch: i32
	data := stbi.load(cpath, &x, &y, &ch, 4)
	if data == nil {
		return nil, 0, 0, false
	}
	defer stbi.image_free(data)
	pixels = make([]u8, int(x * y * 4), context.temp_allocator)
	copy(pixels, data[:x * y * 4])
	return pixels, u32(x), u32(y), true
}
