// Rendered RGBA8 frame to the encoder's NV12 planes (Y, then interleaved
// U and V: the layout Vulkan Video encodes), on the GPU, so the readback is
// 1.5 bytes a pixel instead of 4 and the CPU converts nothing.
// Same Q16 fixed point as oicut's movie writer (rgb_to_yuv_coefficients) and
// encode/encode.odin's CPU path, so every backend writes identical planes.
//
// One invocation owns an 8x2 pixel block: two Y words per row and two UV
// words, so no two invocations write the same word. Both planes are packed
// in `destination` with `y_stride` (a multiple of 8) bytes per row.
//
// SDL_GPU compute bindings: set 0 read-only storage textures, set 1
// read-write storage buffers, set 2 uniforms (Metal: texture 0, buffer 0
// uniforms, buffer 1 storage). The frame is read as a storage texture, not
// sampled: SDL_GPU's sampler barriers only cover the vertex and fragment
// stages, so a compute pass sampling a texture rendered just before could
// read it before the render finished; a storage read gets a barrier from
// the color target to the compute stage.

[[vk::binding(0, 0)]] [[vk::image_format("rgba8")]] RWTexture2D<float4> source : register(u0, space0);
[[vk::binding(0, 1)]] RWByteAddressBuffer destination : register(u1, space1);

struct Params {
	int4 ky; // R, G, B weights, y bias (Q16)
	int4 ku; // R, G, B weights, chroma bias (Q18, for a 2x2 sum)
	int4 kv; // R, G, B weights, chroma max
	uint4 size; // width, height, y_stride, uv plane offset (bytes)
};
[[vk::binding(0, 2)]] ConstantBuffer<Params> params : register(b0, space2);

int3 texel(int x, int y) {
	float4 c = source[uint2(min(x, int(params.size.x) - 1), min(y, int(params.size.y) - 1))];
	return int3(round(c.rgb * 255.0));
}

uint luma(int3 c) {
	return uint(clamp((params.ky.x * c.r + params.ky.y * c.g + params.ky.z * c.b + params.ky.w) >> 16, 0, 255));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 id: SV_DispatchThreadID) {
	uint y_stride = params.size.z;
	if (id.x * 8 >= y_stride || id.y * 2 >= params.size.y) return;
	int x0 = int(id.x * 8);
	int y0 = int(id.y * 2);
	uint y_words[4] = { 0, 0, 0, 0 };
	uint uv_words[2] = { 0, 0 };
	for (int i = 0; i < 4; ++i) {
		int x = x0 + i * 2;
		int3 a = texel(x, y0);
		int3 b = texel(x + 1, y0);
		int3 c = texel(x, y0 + 1);
		int3 d = texel(x + 1, y0 + 1);
		uint word = uint(i / 2);
		uint shift = uint(i % 2) * 16;
		y_words[word] |= (luma(a) | (luma(b) << 8)) << shift;
		y_words[word + 2] |= (luma(c) | (luma(d) << 8)) << shift;
		int3 s = a + b + c + d;
		uint u = uint(clamp((params.ku.x * s.r + params.ku.y * s.g + params.ku.z * s.b + params.ku.w) >> 18, 0, params.kv.w));
		uint v = uint(clamp((params.kv.x * s.r + params.kv.y * s.g + params.kv.z * s.b + params.ku.w) >> 18, 0, params.kv.w));
		uv_words[i / 2] |= (u | (v << 8)) << shift;
	}
	uint row0 = uint(y0) * y_stride + id.x * 8;
	destination.Store(row0, y_words[0]);
	destination.Store(row0 + 4, y_words[1]);
	destination.Store(row0 + y_stride, y_words[2]);
	destination.Store(row0 + y_stride + 4, y_words[3]);
	uint chroma = params.size.w + id.y * y_stride + id.x * 8;
	destination.Store(chroma, uv_words[0]);
	destination.Store(chroma + 4, uv_words[1]);
}
