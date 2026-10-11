// Buffer B, the glow: this frame's ink (iChannel0, Buffer A, which runs
// first) spread over a golden-angle disc.
#define TAPS 16

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int i = 0; i < TAPS; i++) {
        float fi = float(i) + 0.5;
        float r = sqrt(fi / float(TAPS)) * 14.0;
        float a = fi * 2.39996323;
        float w = exp(-r * r / 90.0);
        sum += texture(iChannel0, (fragCoord + r * vec2(cos(a), sin(a))) / iResolution.xy).rgb * w;
        total += w;
    }
    fragColor = vec4(sum / total, 1.0);
}
