package animation

import "core:math"
import ease "core:math/ease"

// A track addresses a numeric register supplied by its owner. Current is stored
// exactly once in that owner; tracks are plain contiguous data with no pointers.
Space :: enum u8 {
	Linear,
	Logarithmic,
}
Track :: struct {
	start, target:     f32,
	elapsed, duration: f32,
	easing:            ease.Ease,
	space:             Space,
	rate:              f32, // >0 selects exponential convergence instead of a duration
	active:            bool,
}

target :: proc(
	t: ^Track,
	current, value: f32,
	duration: f32 = 0.18,
	easing: ease.Ease = .Cubic_Out,
	space: Space = .Linear,
	rate: f32 = 0,
) {
	t^ = {
		start    = current,
		target   = value,
		duration = duration,
		easing   = easing,
		space    = space,
		rate     = rate,
		active   = current != value,
	}
}

interpolate :: proc(a, b, fraction: f32, space: Space) -> f32 {
	if space == .Logarithmic && a > 0 && b > 0 do return math.exp(math.ln(a) + (math.ln(b) - math.ln(a)) * fraction)
	return a + (b - a) * fraction
}

// Shared exponential primitive for transient interaction registers as well.
approach :: proc(current, target, rate, dt: f32) -> f32 {
	return current + (target - current) * (1 - math.exp(-rate * max(dt, 0)))
}

advance :: proc(current: ^f32, t: ^Track, dt: f32) -> bool {
	if !t.active do return false
	if t.rate > 0 {
		fraction := dt <= 0 ? f32(1) : 1 - math.exp(-t.rate * dt)
		current^ = interpolate(current^, t.target, fraction, t.space)
		distance :=
			t.space == .Logarithmic && current^ > 0 && t.target > 0 ? math.abs(math.ln(t.target) - math.ln(current^)) : math.abs(t.target - current^)
		if distance <= 1e-4 {current^ = t.target; t.active = false}
	} else {
		t.elapsed = min(t.elapsed + max(dt, 0), t.duration)
		progress := t.duration > 0 ? t.elapsed / t.duration : 1
		current^ = interpolate(t.start, t.target, ease.ease(t.easing, progress), t.space)
		if progress >= 1 {current^ = t.target; t.active = false}
	}
	return t.active
}
