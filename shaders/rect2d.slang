// pipe_rect2d: one instanced quad per UI/2D rect, four vertices from the
// vertex id (triangle strip), every attribute per instance; the fragment
// stage is an SDF rounded rect with border, edge softness, and a sample mode
// (solid, rgba texture, alpha glyph, nearest texel, palette over a
// single-channel texture: the colour carries max_raw, invalid_raw,
// palette (0 ramp, 1 grey, 2 heat), and log (1 for log(1 + value));
// polar over a float texture whose
// rows are ranges and columns angles: the quad is the sector's square,
// the radii carry angle_min, angle_increment, and the inner range as a
// fraction of the outer). Vulkan y-down NDC.
// SDL_GPU binding convention: vertex uniforms set 1, fragment samplers set 2.

struct Instance {
    float4 dst    : TEXCOORD0; // x0,y0,x1,y1 (pixels)
    float4 src    : TEXCOORD1; // u0,v0,u1,v1 (texels)
    float4 col_tl : TEXCOORD2;
    float4 col_tr : TEXCOORD3;
    float4 col_bl : TEXCOORD4;
    float4 col_br : TEXCOORD5;
    float4 radii  : TEXCOORD6; // TL,TR,BL,BR corner radii (px)
    float4 style  : TEXCOORD7; // border_thickness, edge_softness, sample_mode, _
};

struct Varyings {
    float4 clip   : SV_Position;
    float2 uv     : TEXCOORD0;
    float4 color  : TEXCOORD1;
    float2 pos    : TEXCOORD2; // fragment position (px)
    float2 center : TEXCOORD3; // rect center (px)
    float2 half   : TEXCOORD4; // rect half-size (px)
    float4 radii  : TEXCOORD5;
    float4 style  : TEXCOORD6;
    float2 tex_size : TEXCOORD7; // texels, for the nearest-texel mode
};

struct VS {
    float2 viewport; // framebuffer size in pixels
    float2 tex_size; // bound texture size in texels (for src -> uv)
};
[[vk::binding(0, 1)]] ConstantBuffer<VS> vs : register(b0, space1);

[[vk::binding(0, 2)]] Sampler2D u_tex : register(t0, space2);

[shader("vertex")]
Varyings vs_main(Instance a, uint vertex_id : SV_VertexID) {
    // 0=TL, 1=TR, 2=BL, 3=BR (strip -> tris TL,TR,BL & TR,BL,BR)
    int ix = (vertex_id == 1 || vertex_id == 3) ? 1 : 0;
    int iy = (vertex_id >= 2) ? 1 : 0;
    float2 p  = float2(ix == 0 ? a.dst.x : a.dst.z, iy == 0 ? a.dst.y : a.dst.w);
    float2 uv = float2(ix == 0 ? a.src.x : a.src.z, iy == 0 ? a.src.y : a.src.w);
    float4 col;
    if      (ix == 0 && iy == 0) col = a.col_tl;
    else if (ix == 1 && iy == 0) col = a.col_tr;
    else if (ix == 0 && iy == 1) col = a.col_bl;
    else                         col = a.col_br;

    Varyings o;
    o.uv     = (vs.tex_size.x > 0.0) ? uv / vs.tex_size : uv;
    o.color  = col;
    o.pos    = p;
    o.center = 0.5 * (a.dst.xy + a.dst.zw);
    o.half   = 0.5 * abs(a.dst.zw - a.dst.xy);
    o.radii  = a.radii;
    o.style  = a.style;
    o.tex_size = vs.tex_size;
    float2 ndc = float2(2.0 * p.x / vs.viewport.x - 1.0,
                        1.0 - 2.0 * p.y / vs.viewport.y); // pixel top-left -> NDC +1 top
    o.clip = float4(ndc, 0.0, 1.0);
    return o;
}

// palette_rgb colours a value against its maximum: 0 the ramp (yellow
// near to blue far), 1 grey, 2 heat (black, red, yellow, white); with
// `log` the position on the palette is log(1 + value) against log(1 + max)
float3 palette_rgb(float raw, float max_raw, float palette, float log_curve) {
    float t;
    if (log_curve > 0.5) t = clamp(log(1.0 + max(raw, 0.0)) / log(1.0 + max(max_raw, 1e-6)), 0.0, 1.0);
    else                 t = clamp(raw / max(max_raw, 1e-6), 0.0, 1.0);
    if (palette > 1.5) {
        float3 heat;
        if      (t < 1.0 / 3.0) heat = float3(3.0 * t, 0.0, 0.0);
        else if (t < 2.0 / 3.0) heat = float3(1.0, 3.0 * t - 1.0, 0.0);
        else                    heat = float3(1.0, 1.0, 3.0 * t - 2.0);
        return heat;
    }
    if (palette > 0.5) return float3(t, t, t);
    return lerp(float3(250.0, 204.0, 21.0), float3(40.0, 90.0, 200.0), t) / 255.0;
}

float rounded_box_sdf(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

[shader("fragment")]
float4 fs_main(Varyings v) : SV_Target {
    float2 p = v.pos - v.center;
    // corner radius by quadrant: TL,TR,BL,BR
    float r;
    if      (p.x <  0.0 && p.y <  0.0) r = v.radii.x;
    else if (p.x >= 0.0 && p.y <  0.0) r = v.radii.y;
    else if (p.x <  0.0 && p.y >= 0.0) r = v.radii.z;
    else                               r = v.radii.w;

    float border   = v.style.x;
    float softness = max(v.style.y, 0.0);
    int   mode     = int(v.style.z + 0.5); // 0 solid, 1 rgba tex, 2 alpha glyph, 3 nearest texel, 4 palette, 5 polar

    if (mode == 5) {
        // a sector: the fragment's range and angle from the square's
        // centre pick the texel (row = range, column = angle); outside
        // the sector, or where the texel is NaN (no reading), nothing
        float2 size = max(v.tex_size, float2(1.0, 1.0));
        float radius = max(v.half.x, 1.0);
        float range = length(p) / radius;
        float angle = atan2(-p.x, -p.y);
        float angle_min = v.radii.x;
        float angle_step = v.radii.y;
        float rel = angle - angle_min;
        // the nearest turn of the angle into the sector's span
        float span = angle_step * size.x;
        if (span > 0.0) { while (rel < 0.0 && rel + 6.28318530718 <= span) rel += 6.28318530718; while (rel > span && rel - 6.28318530718 >= 0.0) rel -= 6.28318530718; }
        else            { while (rel > 0.0 && rel - 6.28318530718 >= span) rel -= 6.28318530718; while (rel < span && rel + 6.28318530718 <= 0.0) rel += 6.28318530718; }
        float column = abs(angle_step) > 1e-9 ? rel / angle_step : -1.0;
        float inner = clamp(v.radii.z, 0.0, 0.999);
        if (range > 1.0 || range < inner || column < 0.0 || column >= size.x) return float4(0.0, 0.0, 0.0, 0.0);
        float row = (range - inner) / (1.0 - inner) * size.y;
        float2 pixel = clamp(floor(float2(column, row)), float2(0.0, 0.0), size - float2(1.0, 1.0));
        float raw = u_tex.Sample((pixel + float2(0.5, 0.5)) / size).r;
        if (isnan(raw)) return float4(28.0, 30.0, 38.0, 255.0) / 255.0;
        return float4(palette_rgb(raw, v.color.x, v.color.z, v.color.w), 1.0);
    }

    float aa    = softness + 0.5;
    float dist  = rounded_box_sdf(p, v.half, r);
    float alpha = 1.0 - smoothstep(-aa, aa, dist);
    if (border > 0.0) {
        float inner = rounded_box_sdf(p, v.half - float2(border, border), max(r - border, 0.0));
        float inner_alpha = 1.0 - smoothstep(-aa, aa, inner);
        alpha = clamp(alpha - inner_alpha, 0.0, 1.0);
    }

    float4 tex;
    if      (mode == 1) tex = u_tex.Sample(v.uv);
    else if (mode == 2) tex = float4(1.0, 1.0, 1.0, u_tex.Sample(v.uv).r);
    else if (mode == 3) {
        // nearest texel: sample at the texel's centre, where any filter
        // returns the texel itself (no Load, which not every target has
        // for a combined sampler)
        float2 size = max(v.tex_size, float2(1.0, 1.0));
        float2 pixel = clamp(floor(v.uv * size), float2(0.0, 0.0), size - float2(1.0, 1.0));
        tex = u_tex.Sample((pixel + float2(0.5, 0.5)) / size);
    }
    else if (mode == 4) {
        // a frame's elements through its palette, on the GPU: the texel is
        // a raw value over 65535, the colour holds the raw value at the far
        // end of the ramp, the raw value meaning "no reading" (-1 for
        // none), and the palette (0 ramp, 1 grey)
        float2 size = max(v.tex_size, float2(1.0, 1.0));
        float2 pixel = clamp(floor(v.uv * size), float2(0.0, 0.0), size - float2(1.0, 1.0));
        float raw = u_tex.Sample((pixel + float2(0.5, 0.5)) / size).r * 65535.0;
        bool invalid = v.color.y >= 0.0 && abs(raw - v.color.y) < 0.5;
        float3 rgb = invalid ? float3(28.0, 30.0, 38.0) / 255.0 : palette_rgb(raw, v.color.x, v.color.z, v.color.w);
        float4 o = float4(rgb, alpha);
        return o;
    }
    else                tex = float4(1.0, 1.0, 1.0, 1.0);

    float4 o = v.color * tex;
    o.a *= alpha;
    return o;
}
