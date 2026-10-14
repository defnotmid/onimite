package ui

import "core:math"
import ease "core:math/ease"

// Keyed animation, raddbg's ui_anim, extended with oasic's logarithmic space
// and exponential convergence rate: any code that shows a number asks for it
// by key with the target it should reach, and the table brings the shown
// value there over `duration` (or at exponential `rate` > 0). State keeps
// only targets; smoothing lives at the point of use, or in an explicit Track
// / Scroll register owned by a view.
Animation_Space :: enum u8 {
	Linear,
	Logarithmic,
}

Animation_Params :: struct {
	initial:  f64,
	duration: f32,
	easing:   ease.Ease,
	space:    Animation_Space,
	rate:     f32, // > 0 selects exponential convergence instead of a duration
	reset:    bool,
}

Animation_Row :: struct {
	key:                      Key,
	current:                  f64,
	start:                    f64,
	target:                   f64,
	elapsed:                  f32,
	duration:                 f32,
	easing:                   ease.Ease,
	space:                    Animation_Space,
	rate:                     f32,
	last_touched_build_index: u64,
}

// A track addresses a numeric register supplied by its owner (oasic's
// animation.Track). Current is stored in that owner; tracks are plain data.
Track :: struct {
	start, target:     f64,
	elapsed, duration: f32,
	easing:            ease.Ease,
	space:             Animation_Space,
	rate:              f32, // > 0 selects exponential convergence instead of a duration
	active:            bool,
}

track_target :: proc(
	t: ^Track,
	current, value: f64,
	duration: f32 = 0.18,
	easing: ease.Ease = .Cubic_Out,
	space: Animation_Space = .Linear,
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

interpolate :: proc(a, b, fraction: f64, space: Animation_Space) -> f64 {
	if space == .Logarithmic && a > 0 && b > 0 {
		return math.exp(math.ln(a) + (math.ln(b) - math.ln(a)) * fraction)
	}
	return a + (b - a) * fraction
}

track_advance :: proc(current: ^f64, t: ^Track, dt: f32) -> bool {
	if !t.active {
		return false
	}
	if t.rate > 0 {
		fraction := f64(1) if dt <= 0 else 1 - math.exp(-f64(t.rate * dt))
		current^ = interpolate(current^, t.target, fraction, t.space)
		distance := math.abs(math.ln(t.target) - math.ln(current^)) if t.space == .Logarithmic && current^ > 0 && t.target > 0 else math.abs(t.target - current^)
		if distance <= 1e-4 {
			current^ = t.target
			t.active = false
		}
	} else {
		t.elapsed = min(t.elapsed + max(dt, 0), t.duration)
		progress := t.elapsed / t.duration if t.duration > 0 else 1
		current^ = interpolate(t.start, t.target, f64(ease.ease(t.easing, progress)), t.space)
		if progress >= 1 {
			current^ = t.target
			t.active = false
		}
	}
	return t.active
}

// A scroll register in rows or points (oasic's animation.Scroll). The owner
// supplies bounds; interpolation, clamping and fractional paging are shared.
Scroll :: struct {
	current, maximum: f64,
	track:            Track,
}

scroll_to :: proc(s: ^Scroll, value: f64) {
	v := clamp(value, 0, s.maximum)
	if v != s.track.target {
		track_target(&s.track, s.current, v)
	}
}

scroll_by :: proc(s: ^Scroll, delta: f64) {
	scroll_to(s, s.track.target + delta)
}

scroll_limit :: proc(s: ^Scroll, maximum: f64) {
	s.maximum = max(0, maximum)
	s.current = clamp(s.current, 0, s.maximum)
	v := clamp(s.track.target, 0, s.maximum)
	if v != s.track.target || s.current == v {
		track_target(&s.track, s.current, v)
	}
}

scroll_advance :: proc(s: ^Scroll, dt: f32) -> bool {
	return track_advance(&s.current, &s.track, dt)
}

scroll_page_reg :: proc(s: ^State, scroll: ^Scroll) -> (first: int, fraction: f32) {
	if scroll_advance(scroll, s.p.frame_time) {
		s.is_animating = true
	}
	first = int(max(0, scroll.current))
	fraction = f32(max(0, scroll.current) - f64(first))
	return
}

Animation_Storage :: struct {
	rows:             [dynamic]Animation_Row,
	row_index_by_key: map[Key]u32,
}

animation_storage_make :: proc() -> Animation_Storage {
	return {
		rows = make([dynamic]Animation_Row),
		row_index_by_key = make(map[Key]u32),
	}
}

animation_storage_destroy :: proc(storage: ^Animation_Storage) {
	delete(storage.rows)
	delete(storage.row_index_by_key)
	storage^ = {}
}

animation_storage_remove_row :: proc(storage: ^Animation_Storage, row_index: int) {
	last_index := len(storage.rows) - 1
	removed_key := storage.rows[row_index].key
	if row_index != last_index {
		storage.rows[row_index] = storage.rows[last_index]
		storage.row_index_by_key[storage.rows[row_index].key] = u32(row_index)
	}
	pop(&storage.rows)
	delete_key(&storage.row_index_by_key, removed_key)
}

animation_storage_prune :: proc(storage: ^Animation_Storage, build_index: u64) {
	row_index := 0
	for row_index < len(storage.rows) {
		row := storage.rows[row_index]
		if row.last_touched_build_index + 2 < build_index {
			animation_storage_remove_row(storage, row_index)
		} else {
			row_index += 1
		}
	}
}

// anim_f32 returns persistent keyed animation state. New or reappearing keys
// start at params.initial; build_end advances touched rows toward target.
anim_f32 :: proc(s: ^State, key: Key, target: f32, params: Animation_Params = {}) -> f32 {
	return f32(anim_f64(s, key, f64(target), params))
}

anim_f64 :: proc(
	s: ^State,
	key: Key,
	target: f64,
	params: Animation_Params = {},
) -> f64 {
	if key == Key(0) {
		return target
	}

	row_index: int
	row_is_new := false
	if stored_index, ok := s.animations.row_index_by_key[key]; ok {
		row_index = int(stored_index)
	} else {
		row_index = len(s.animations.rows)
		append(&s.animations.rows, Animation_Row{key = key})
		s.animations.row_index_by_key[key] = u32(row_index)
		row_is_new = true
	}

	row := &s.animations.rows[row_index]
	reappeared := !row_is_new && row.last_touched_build_index + 1 < s.build_index
	if row_is_new || reappeared || params.reset {
		row.current = params.initial
		row.start = params.initial
		row.elapsed = 0
	} else if row.target != target {
		row.start = row.current
		row.elapsed = 0
	}
	row.target = target
	row.duration = params.duration > 0 ? params.duration : 0.2
	row.easing = params.easing
	row.space = params.space
	row.rate = params.rate
	row.last_touched_build_index = s.build_index
	if (row.rate <= 0 && row.duration <= 0) || row.target == row.current {
		row.current = row.target
	}
	return row.current
}

animations_advance :: proc(s: ^State) {
	dt := max(s.p.frame_time, 0)
	for row_index in 0 ..< len(s.animations.rows) {
		row := &s.animations.rows[row_index]
		if row.last_touched_build_index != s.build_index {
			continue
		}
		if row.rate > 0 {
			fraction := f64(1) if dt <= 0 else 1 - math.exp(-f64(row.rate * dt))
			row.current = interpolate(row.current, row.target, fraction, row.space)
			distance := math.abs(math.ln(row.target) - math.ln(row.current)) if row.space == .Logarithmic && row.current > 0 && row.target > 0 else math.abs(row.target - row.current)
			if distance <= 1e-4 {
				row.current = row.target
			} else {
				s.is_animating = true
			}
		} else {
			row.elapsed = min(row.elapsed + dt, row.duration)
			progress := row.duration > 0 ? row.elapsed / row.duration : 1
			t := f64(ease.ease(row.easing, progress))
			row.current = interpolate(row.start, row.target, t, row.space)
			if progress >= 1 || math.abs(row.target - row.current) <= 1.0e-9 * max(math.abs(row.target), 1) {
				row.current = row.target
			} else {
				s.is_animating = true
			}
		}
	}
}
