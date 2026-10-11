// Image: ink plus glow over a dark ground, softly tone mapped.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec3 ink = texture(iChannel0, uv).rgb;
    vec3 glow = texture(iChannel1, uv).rgb;
    vec3 ground = mix(vec3(0.010, 0.012, 0.030), vec3(0.035, 0.020, 0.060), uv.y);
    vec3 col = 1.0 - exp(-(ground + ink * 0.85 + glow * 0.9) * 1.7);
    vec2 v = (uv - 0.5) * vec2(iResolution.x / iResolution.y, 1.0);
    col *= mix(0.5, 1.0, smoothstep(1.2, 0.3, length(v)));
    fragColor = vec4(col, 1.0);
}
