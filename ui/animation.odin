package ui

import "core:math"
import ease "core:math/ease"

// Keyed animation, raddbg's ui_anim: any code that shows a number asks for
// it by key with the target it should reach, and the table brings the shown
// value there over `duration`. State keeps only targets; smoothing lives at
// the point of use, so a chart window, a camera distance, and a widget's
// hover all move the same way and nothing registers anything.
Animation_Params :: struct {
	initial:  f64,
	duration: f32,
	easing:   ease.Ease,
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
	last_touched_build_index: u64,
}

Animation_Storage :: struct {
	rows:           [dynamic]Animation_Row,
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
	row.last_touched_build_index = s.build_index
	if row.duration <= 0 || row.target == row.current {
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
		row.elapsed = min(row.elapsed + dt, row.duration)
		progress := row.duration > 0 ? row.elapsed / row.duration : 1
		t := f64(ease.ease(row.easing, progress))
		row.current = row.start + (row.target - row.start) * t
		if progress >= 1 || math.abs(row.target - row.current) <= 1.0e-9 * max(math.abs(row.target), 1) {
			row.current = row.target
		} else {
			s.is_animating = true
		}
	}
}
