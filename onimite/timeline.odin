package onimite

import "core:math"
import easings "core:math/ease"
import vg "deps:ovg"

// Keyframe animation, a port of fframes' `timeline!` / `KeyFramesAnimation`.
//
//     y := om.animate(f, []om.Key(f32){
//         {start = 0, end = 0.4, from = 60, to = 0, easing = om.EASE_OUT},
//         {start = 2.5, from = 0, to = -40, easing = om.spring(1, 180, 20)},
//     })
//
// Times are seconds relative to the frame's clock (scene-relative inside a
// scene). Before the first key the value is its `from`; between keys it
// holds the previous `to`; after the last key it stays at its `to`.

Easing_Kind :: enum u8 {
	Linear,
	Cubic_Bezier,
	Spring,
	Named, // one of Odin's `core:math/ease` curves, `ease.Ease` in p[0]
}

Easing :: struct {
	kind: Easing_Kind,
	// Cubic bezier control points (x1, y1, x2, y2), spring
	// (mass, stiffness, damping, _), or the `ease.Ease` of a named curve.
	p:    [4]f32,
}

LINEAR :: Easing{}
// Odin's cubic curves (core:math/ease). fframes' CSS beziers are
// `cubic_bezier(0.42, 0, 1, 1)`, `(0, 0, 0.58, 1)` and `(0.42, 0, 0.58, 1)`.
EASE_IN :: Easing{.Named, {f32(easings.Ease.Cubic_In), 0, 0, 0}}
EASE_OUT :: Easing{.Named, {f32(easings.Ease.Cubic_Out), 0, 0, 0}}
EASE_IN_OUT :: Easing{.Named, {f32(easings.Ease.Cubic_In_Out), 0, 0, 0}}

cubic_bezier :: proc "contextless" (x1, y1, x2, y2: f32) -> Easing {
	return {.Cubic_Bezier, {clamp(x1, 0, 1), y1, clamp(x2, 0, 1), y2}}
}

// A `core:math/ease` curve (quadratic, cubic, ... elastic, back, bounce).
named :: proc "contextless" (e: easings.Ease) -> Easing {
	return {.Named, {f32(e), 0, 0, 0}}
}

spring :: proc "contextless" (mass: f32 = 1, stiffness: f32 = 100, damping: f32 = 10) -> Easing {
	return {.Spring, {mass, stiffness, damping, 0}}
}

// One tween. `end <= start` means "until the next key starts"; the last key
// needs an `end` unless it is a spring, which then runs until it settles.
// A spring with an `end` is cut off there.
Key :: struct($T: typeid) {
	start:  f32,
	end:    f32,
	from:   T,
	to:     T,
	easing: Easing,
}

// The value of the timeline at the frame's time.
animate :: proc(f: Frame, keys: []Key($T)) -> T {
	return sample(keys, frame_seconds(f))
}

// Like `animate`, repeating the timeline (first key start to last key end).
animate_loop :: proc(f: Frame, keys: []Key($T)) -> T {
	if len(keys) == 0 {
		return {}
	}
	first := keys[0].start
	last := keys[len(keys) - 1]
	total := (last.end if last.end > last.start else last.start) - first
	t := frame_seconds(f)
	if total > 0 {
		t = first + math.mod(t - first, total)
	}
	return sample(keys, t)
}

// The value of the timeline at `t` seconds.
sample :: proc(keys: []Key($T), t: f32) -> T {
	if len(keys) == 0 {
		return {}
	}
	if t < keys[0].start {
		return keys[0].from
	}
	for k, i in keys {
		if t < k.start {
			// In the gap after the previous key.
			return keys[i - 1].to
		}
		duration := key_duration(keys, i)
		if t < k.start + duration {
			return lerp(k.from, k.to, ease(k.easing, t - k.start, duration))
		}
	}
	return keys[len(keys) - 1].to
}

@(private)
key_duration :: proc(keys: []Key($T), i: int) -> f32 {
	k := keys[i]
	d: f32
	switch {
	case k.end > k.start:
		d = k.end - k.start
	case i + 1 < len(keys):
		d = keys[i + 1].start - k.start
	case k.easing.kind == .Spring:
		d = math.F32_MAX
	case:
		return 0
	}
	if k.easing.kind == .Spring {
		d = min(d, spring_duration(k.easing))
	}
	return d
}

// Progress (0 to 1, may overshoot for springs and some beziers) after `t`
// seconds of a tween lasting `duration`.
ease :: proc "contextless" (e: Easing, t, duration: f32) -> f32 {
	switch e.kind {
	case .Linear:
		return clamp(t / duration, 0, 1) if duration > 0 else 1
	case .Cubic_Bezier:
		return bezier_solve(e.p, t / duration if duration > 0 else 1)
	case .Spring:
		return spring_solve(e, max(t, 0))
	case .Named:
		return easings.ease(easings.Ease(int(e.p[0])), clamp(t / duration, 0, 1) if duration > 0 else 1)
	}
	return 1
}

// ---- springs (after WebKit's spring.js, as in fframes) -------------------------

@(private)
Spring_Params :: struct {
	zeta, w0, wd, a, b: f32,
}

@(private)
spring_params :: proc "contextless" (e: Easing) -> (s: Spring_Params) {
	mass, stiffness, damping := e.p[0], e.p[1], e.p[2]
	s.zeta = damping / (2 * math.sqrt(stiffness * mass))
	s.w0 = math.sqrt(stiffness / mass)
	s.a = 1
	if s.zeta < 1 {
		// Under-damped.
		s.wd = s.w0 * math.sqrt(1 - s.zeta * s.zeta)
		s.b = s.zeta * s.w0 / s.wd
	} else {
		// Critically damped (over-damped springs use the same curve).
		s.b = s.w0
	}
	return
}

spring_solve :: proc "contextless" (e: Easing, t: f32) -> f32 {
	s := spring_params(e)
	p: f32
	if s.zeta < 1 {
		p = math.exp(-t * s.zeta * s.w0) * (s.a * math.cos(s.wd * t) + s.b * math.sin(s.wd * t))
	} else {
		p = (s.a + s.b * t) * math.exp(-t * s.w0)
	}
	return 1 - p
}

// Seconds until the spring stays within 0.1% of its target.
spring_duration :: proc "contextless" (e: Easing) -> f32 {
	SETTLED :: 0.001
	s := spring_params(e)
	if s.zeta < 1 {
		// The oscillation is bounded by its exponential envelope.
		amp := math.sqrt(s.a * s.a + s.b * s.b)
		return math.ln(amp / SETTLED) / (s.zeta * s.w0)
	}
	// (1 + w0 t) e^(-w0 t) decreases monotonically: step to the threshold.
	t: f32 = 0
	for (s.a + s.b * t) * math.exp(-t * s.w0) > SETTLED {
		t += 1.0 / 240
	}
	return t
}

// ---- cubic bezier (a port of gre/bezier-easing, as in fframes) ------------------

bezier_solve :: proc "contextless" (p: [4]f32, x: f32) -> f32 {
	x1, y1, x2, y2 := p[0], p[1], p[2], p[3]
	if x1 == y1 && x2 == y2 {
		return clamp(x, 0, 1)
	}
	if !(x > 0 && x < 1) {
		return clamp(x, 0, 1)
	}
	X1, Y1, X2, Y2 := f64(x1), f64(y1), f64(x2), f64(y2)
	t := solve_t_for_x(f64(x), (3 * X1 - 3 * X2 + 1) / 2, X2 - 2 * X1, X1)
	return f32((((3 * Y1 - 3 * Y2 + 1) * t + 3 * (Y2 - 2 * Y1)) * t + 3 * Y1) * t)
}

// Solves x(t) = ((2a t + 3b) t + 3c) t for t, with x in (0, 1). u = 1/t is
// the largest real root of x u^3 - 3c u^2 - 3b u - 2a = 0.
@(private)
solve_t_for_x :: proc "contextless" (x, a, b, c: f64) -> f64 {
	j := 1 / max(c, math.sqrt(x))
	k := x * j
	l := k * j
	s := c * j
	q := b * l
	m := s * s + q
	h := -s * (s * s + 1.5 * q) - a * k * l
	d := h * h - m * m * m
	v: f64
	if m == 0 || d > 1e-12 * h * h {
		// One real root (Cardano).
		w := h - math.sqrt(d) if h < 0 else h + math.sqrt(d)
		u := -math.cbrt(w)
		v = u + m / u
		if math.is_nan(v) {
			v = 0
		}
	} else {
		// Three real roots: take the largest.
		r := math.sqrt(m)
		v = 2 * r * math.cos(math.acos(clamp(-h / (m * r), -1, 1)) / 3)
	}
	return min(k / (v + s), 1)
}

// ---- interpolation ------------------------------------------------------------------

lerp_f32 :: proc "contextless" (a, b: f32, t: f32) -> f32 {
	return a + (b - a) * t
}

lerp_vec2 :: proc "contextless" (a, b: Vec2, t: f32) -> Vec2 {
	return a + (b - a) * t
}

lerp_color :: proc "contextless" (a, b: Color, t: f32) -> Color {
	return {a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t}
}

// Matrices (either side) interpolate component-wise.
lerp_transform :: proc "contextless" (a, b: Transform, t: f32) -> Transform {
	if a.affine != nil || b.affine != nil {
		ma, mb := transform_matrix(a), transform_matrix(b)
		m: vg.Transform2D
		for i in 0 ..< 6 {
			m[i] = lerp_f32(ma[i], mb[i], t)
		}
		return affine(m)
	}
	return {
		translate = lerp_vec2(a.translate, b.translate, t),
		scale = lerp_vec2(a.scale, b.scale, t),
		rotate = lerp_f32(a.rotate, b.rotate, t),
		skew = lerp_vec2(a.skew, b.skew, t),
		origin = lerp_vec2(a.origin, b.origin, t),
	}
}

lerp :: proc {
	lerp_f32,
	lerp_vec2,
	lerp_color,
	lerp_transform,
}
