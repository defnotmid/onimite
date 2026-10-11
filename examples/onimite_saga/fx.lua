-- The film's shaders (oksl compiles them: SkSL for the backdrops, the glitch
-- and Pip's dissolve; Shadertoy GLSL for the tunnel and the matrix rain) and
-- the thin wrappers the scenes call.

local look = require("look")

local M = {}

-- ---- SkSL ---------------------------------------------------------------------

local FOG = [[
uniform float3 iResolution;
uniform float iTime;
uniform float uDim;
uniform float uPulse;
uniform half4 uTint;

float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.547); }
float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p = p * 2.03 + float2(17.1, 3.7);
        a *= 0.5;
    }
    return v;
}

half4 main(float2 coord) {
    float2 p = coord / iResolution.y;
    float t = iTime * 0.12;
    float2 q = float2(fbm(p * 2.0 + t), fbm(p * 2.0 + float2(5.2, 1.3) - t));
    float v = fbm(p * 2.0 + q * 2.2 + t * 0.6);
    float3 tint = float3(uTint.rgb);
    float3 col = mix(float3(0.012, 0.012, 0.03), tint, v * v * 2.2);
    col += tint * 0.5 * uPulse * v;
    float2 c = coord / iResolution.xy - 0.5;
    col *= 1.0 - dot(c, c) * 1.6;
    col *= uDim;
    return half4(col, 1.0);
}
]]

-- K-pop backdrops. uMode: 0 plasma, 1 halftone rings, 2 tunnel, 3 rays,
-- 4 checker; uPulse is the kick (1 on the beat, decaying).
local POP = [[
uniform float3 iResolution;
uniform float iTime;
uniform float uMode;
uniform float uPulse;
uniform half4 uA;
uniform half4 uB;
uniform half4 uC;

half4 main(float2 coord) {
    float2 p = (coord - iResolution.xy * 0.5) / iResolution.y;
    float t = iTime;
    float3 a = float3(uA.rgb);
    float3 b = float3(uB.rgb);
    float3 c = float3(uC.rgb);
    float3 col = a;
    if (uMode < 0.5) {
        float v = sin(p.x * 7.0 + t * 1.3) + sin(p.y * 8.0 - t * 1.1)
                + sin((p.x + p.y) * 6.0 + t) + sin(length(p) * 12.0 - t * 2.0 - uPulse * 3.0);
        col = mix(a, b, smoothstep(-2.0, 2.0, v));
        col = mix(col, c, smoothstep(1.4, 2.6, v));
    } else if (uMode < 1.5) {
        float s = 48.0;
        float2 g = coord / s;
        float2 id = floor(g);
        float2 f = fract(g) - 0.5;
        float d = length(id * s / iResolution.y - float2(0.5 * iResolution.x / iResolution.y, 0.5));
        float w = 0.5 + 0.5 * sin(d * 7.0 - t * 3.0);
        float r = 0.14 + 0.3 * w + 0.1 * uPulse;
        float m = smoothstep(r, r - 0.07, length(f));
        col = mix(a, b, m);
        col = mix(col, c, m * smoothstep(0.55, 1.0, w));
    } else if (uMode < 2.5) {
        float r = length(p) + 0.001;
        float an = atan(p.y, p.x);
        float z = 0.3 / r + t * 1.6 + uPulse * 0.25;
        float stripes = step(0.5, fract(z));
        float rays = step(0.5, fract(an * 3.0 / 3.14159 + t * 0.15));
        float m = abs(stripes - rays);
        col = mix(a, b, m);
        col = mix(col, c, (1.0 - smoothstep(0.0, 0.7, r)) * 0.55);
        col *= smoothstep(0.0, 0.3, r);
    } else if (uMode < 3.5) {
        float an = atan(p.y, p.x);
        float rays = step(0.5, fract(an * 6.0 / 3.14159 + sin(t * 0.7) * 0.4));
        col = mix(a, b, rays);
        col = mix(col, c, (1.0 - smoothstep(0.0, 0.9, length(p))) * (0.3 + 0.7 * uPulse));
    } else {
        float2 q = p * 7.0 + float2(t * 0.8, t * 0.5) + float2(uPulse * 0.25, 0.0);
        float m = mod(floor(q.x) + floor(q.y), 2.0);
        col = mix(a, b, m);
        col = mix(col, c, smoothstep(0.9, 0.1, length(p)) * 0.5);
    }
    col *= 1.0 - dot(p, p) * 0.5;
    col += float3(uPulse * 0.07);
    return half4(col, 1.0);
}
]]

-- Slices pushed sideways and a colour split over a `uniform shader` child.
local GLITCH = [[
uniform float3 iResolution;
uniform shader uSrc;
uniform float uGlitch;
uniform float uSeed;
uniform float uBand;

float hash(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.547); }

half4 main(float2 coord) {
    float2 p = coord;
    float band = floor(coord.y / uBand);
    if (hash(band + uSeed * 13.0) > 1.0 - uGlitch * 0.7) {
        p.x += (hash(band * 7.0 + uSeed) - 0.5) * 420.0 * uGlitch;
    }
    float split = 2.0 + 34.0 * uGlitch;
    half4 r = uSrc.eval(p + float2(split, 0.0));
    half4 g = uSrc.eval(p);
    half4 b = uSrc.eval(p - float2(split, 0.0));
    half4 c = half4(r.r, g.g, b.b, max(g.a, max(r.a, b.a)));
    c.rgb *= 0.92 + 0.08 * sin(coord.y * 3.14159);
    return c;
}
]]

-- Pip (a group child) burns away from the top, the pixels rising as embers.
local DISSOLVE = [[
uniform float3 iResolution;
uniform shader uPip;
uniform float uP;
uniform float uTime;

float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.547); }

half4 main(float2 coord) {
    float cell = 7.0;
    float2 id = floor(coord / cell);
    float n = hash(id);
    float top = 1.0 - coord.y / iResolution.y;
    float burn = uP * 1.5 - 0.25 - top * 0.35 - n * 0.35;
    float rise = clamp(burn, 0.0, 1.0);
    float2 src = coord + float2(sin(n * 40.0 + uTime) * 8.0 * rise, rise * (60.0 + 260.0 * n));
    half4 c = uPip.eval(src);
    float alive = 1.0 - smoothstep(0.0, 0.35, burn);
    float ember = smoothstep(-0.05, 0.1, burn) * (1.0 - smoothstep(0.1, 0.55, burn));
    float3 glow = mix(float3(1.0, 0.35, 0.1), float3(1.0, 0.85, 0.45), n) * ember * c.a;
    half4 o = half4(float3(c.rgb) * alive + glow * 1.4, c.a * (alive + ember * 0.9));
    return o;
}
]]

-- ---- Shadertoy GLSL -----------------------------------------------------------

-- A tunnel in the oksl panel: plain Shadertoy code, nothing translated.
M.TUNNEL = [[
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float r = length(uv) + 0.001;
    float u = atan(uv.y, uv.x) / 6.28318 + iTime * 0.03;
    float z = 0.28 / r + iTime * 0.7;
    vec3 c = 0.5 + 0.5 * cos(6.28318 * (z * 0.35 + u * 2.0 + vec3(0.0, 0.33, 0.67)));
    c *= 0.65 + 0.35 * sin(6.28318 * u * 9.0) * sin(z * 10.0);
    c *= smoothstep(0.0, 0.35, r);
    fragColor = vec4(c, 1.0);
}
]]

-- The matrix: falling glyph columns (a 4x6 bitmap per cell, new bits as the
-- column falls), brighter wherever Pip (iChannel0) or the logo (iChannel1)
-- is; uFade is the whole picture, uPip and uLogo how much of them shows.
M.MATRIX = [[
uniform float uFade;
uniform float uPip;
uniform float uLogo;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 R = iResolution.xy;
    vec2 uv = fragCoord / R;
    float cell = 24.0;
    vec2 g = floor(fragCoord / cell);
    float col = g.x;
    float speed = 5.0 + 9.0 * hash(vec2(col, 1.0));
    float offs = hash(vec2(col, 2.0)) * 200.0;
    float len = 8.0 + 20.0 * hash(vec2(col, 3.0));
    float rows = R.y / cell;
    float head = mod(iTime * speed + offs, rows + len + 6.0) - 3.0;
    float rowTop = rows - g.y;
    float d = head - rowTop;
    float tail = (d >= 0.0 && d < len) ? 1.0 - d / len : 0.0;
    float isHead = (d >= 0.0 && d < 1.0) ? 1.0 : 0.0;

    vec2 lp = fract(fragCoord / cell);
    float tick = floor(iTime * (4.0 + 8.0 * hash(vec2(col, 4.0))) + hash(g) * 9.0);
    vec2 cellbit = floor(lp * vec2(4.0, 6.0));
    float bit = step(0.46, hash(cellbit + g * 7.0 + tick * vec2(1.3, 0.7)));
    vec2 inner = fract(lp * vec2(4.0, 6.0));
    float mask = bit * step(0.16, inner.x) * step(inner.x, 0.84) * step(0.16, inner.y) * step(inner.y, 0.84)
               * step(0.1, lp.x) * step(lp.x, 0.9);

    // Pip sits in the middle, 16:9 like its clip, 80% of the height
    vec2 bsz = vec2(R.y * 0.8 * 16.0 / 9.0, R.y * 0.8);
    vec2 buv = (fragCoord - 0.5 * R) / bsz + 0.5;
    float inb = step(0.0, buv.x) * step(buv.x, 1.0) * step(0.0, buv.y) * step(buv.y, 1.0);
    float boA = texture(iChannel0, buv).a * inb * uPip;
    // the logo, square, filling 70% of the height
    vec2 lsz = vec2(R.y * 0.7, R.y * 0.7);
    vec2 luv = (fragCoord - 0.5 * R) / lsz + 0.5;
    float inl = step(0.0, luv.x) * step(luv.x, 1.0) * step(0.0, luv.y) * step(luv.y, 1.0);
    float lgA = texture(iChannel1, luv).a * inl * uLogo;

    float shape = max(boA, lgA);
    vec3 green = vec3(0.0, 1.0, 0.4);
    float rain = tail * (0.35 + 0.65 * tail) * mask;
    vec3 c = green * rain * (1.0 - 0.6 * shape);
    c += vec3(0.75, 1.0, 0.85) * isHead * mask;
    // glyphs inside the silhouettes stay lit and brighter, with a faint fill
    float lit = mask * (0.45 + 0.55 * hash(g + tick)) * shape;
    c += green * lit * 1.5 + vec3(0.0, 0.14, 0.05) * shape * (0.4 + 0.6 * mask);
    c *= 0.92 + 0.08 * sin(fragCoord.y * 3.14159);
    vec2 vc = uv - 0.5;
    c *= 1.0 - dot(vc, vc) * 1.3;
    fragColor = vec4(c * uFade, 1.0);
}
]]

-- ---- wrappers -------------------------------------------------------------------

local FULL = { x = 0, y = 0, w = look.W, h = look.H }

local function box(o)
  o = o or FULL
  return o.x, o.y, o.w, o.h
end

-- A slow fog over the whole frame. tint: a colour; dim 0..1; pulse 0..1.
function M.fog(f, tint, dim, pulse, area)
  local x, y, w, h = box(area)
  shader(f, { sksl = FOG, x = x, y = y, w = w, h = h,
    uniforms = { uDim = dim or 1, uPulse = pulse or 0, uTint = tint or "#2a1d5c" } })
end

-- A K-pop backdrop: mode 0..4, three colours, the kick pulse.
function M.pop(f, mode, a, b, c, pulse_v, area, time)
  local x, y, w, h = box(area)
  shader(f, { sksl = POP, x = x, y = y, w = w, h = h, time = time,
    uniforms = { uMode = mode, uPulse = pulse_v or 0, uA = a, uB = b, uC = c } })
end

-- `draw` (nodes) glitched by `amount` 0..1 over the box; `seed` changes the slices.
function M.glitch(f, draw, amount, seed, area, band)
  local x, y, w, h = box(area)
  shader(f, { sksl = GLITCH, x = x, y = y, w = w, h = h,
    uniforms = { uSrc = draw, uGlitch = amount, uSeed = seed or 0, uBand = band or 16 } })
end

-- `draw` (the box's units) burning away: p 0..1.
function M.dissolve(f, draw, p, area, t)
  local x, y, w, h = box(area)
  shader(f, { sksl = DISSOLVE, x = x, y = y, w = w, h = h,
    uniforms = { uPip = draw, uP = p, uTime = t or 0 } })
end

-- The Shadertoy tunnel in a box.
function M.tunnel(f, area)
  local x, y, w, h = box(area)
  shader(f, { shadertoy = M.TUNNEL, x = x, y = y, w = w, h = h })
end

-- The rain: Pip's clip and the logo (a drawing function) as channels.
function M.rain(f, fade, pip, logo, logo_draw)
  shader(f, { shadertoy = M.MATRIX, x = 0, y = 0, w = look.W, h = look.H,
    uniforms = { iChannel0 = { src = "transparent.mov", looping = true }, iChannel1 = logo_draw,
      uFade = fade, uPip = pip, uLogo = logo } })
end

return M
