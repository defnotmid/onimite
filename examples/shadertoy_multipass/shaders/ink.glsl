// Buffer A, the ink: last frame's ink (iChannel0, this buffer) drifts
// upstream along the swirl and fades; the comets and the emitter group
// (iChannel1, vector shapes drawn by the script) add fresh colour. Drift,
// fade and colour are rates a second times this frame's share of it
// (iTimeDelta), so the ink looks the same at any frame rate.
uniform float uSwirl;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float aspect = iResolution.x / iResolution.y;
    vec2 q = vec2(uv.x * aspect, uv.y);
    vec2 back = flow(q, iTime, uSwirl) * iTimeDelta;
    vec3 ink = texture(iChannel0, uv - vec2(back.x / aspect, back.y)).rgb * pow(DECAY, iTimeDelta);
    for (int i = 0; i < COMETS; i++) {
        float fi = float(i);
        vec2 d = q - comet(fi, iTime, aspect);
        ink += palette(fi / float(COMETS) + iTime * 0.04) * exp(-dot(d, d) * 5200.0) * 9.6 * iTimeDelta;
    }
    float shape = texture(iChannel1, uv).a;
    ink += palette(0.6 + uv.x * 0.5 + iTime * 0.07) * shape * 3.6 * iTimeDelta;
    fragColor = vec4(ink, 1.0);
}
