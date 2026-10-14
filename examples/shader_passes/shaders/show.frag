#version 300 es
// The trail's density through a cosine palette, as premultiplied colour.
precision highp float;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
uniform sampler2D uTrail;
uniform float iTime;

void main() {
  float k = clamp(texture(uTrail, uv).a, 0.0, 1.0);
  vec3 tint = 0.5 + 0.5 * cos(6.2831 * (vec3(0.0, 0.33, 0.67) + 0.9 * k + 0.04 * iTime));
  float glow = smoothstep(0.0, 0.9, k);
  color = vec4(tint * glow, glow);
}
