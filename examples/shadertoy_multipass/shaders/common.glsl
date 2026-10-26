// Common: shared by every pass (its macros, constants and functions are
// visible in each, as on Shadertoy).

#define COMETS 7
#define DECAY 0.6355 // the ink kept after a second

const float TAU = 6.28318530718;

// A cosine palette from deep violet through rose to amber.
vec3 palette(float t) {
    return vec3(0.55, 0.42, 0.50) + vec3(0.45, 0.40, 0.50) * cos(TAU * (t + vec3(0.00, 0.12, 0.32)));
}

// A divergence-free swirl: the curl of a slowly drifting stream function,
// in units of the screen height per second at q (x across 0..aspect).
vec2 flow(vec2 q, float t, float swirl) {
    float a = 2.1 * q.x + 0.35 * t, b = 1.7 * q.y - 0.25 * t, c = 4.3 * q.x - 3.1 * q.y + 0.6 * t;
    float dx = 0.42 * cos(a) * cos(b) + 0.344 * cos(c);
    float dy = -0.34 * sin(a) * sin(b) - 0.248 * cos(c);
    return vec2(dy, -dx) * swirl;
}

// Comet i's head at time t, same units as flow.
vec2 comet(float i, float t, float aspect) {
    vec2 w = vec2(0.31 + 0.07 * i, 0.43 + 0.05 * i);
    return vec2(0.5 * aspect, 0.5) + vec2(0.36 * aspect, 0.34) * sin(t * w + vec2(1.7 * i, 2.9 * i + 0.4));
}
