package ui

import "../animation"
import "core:math"

// RAD Debugger's default animation rate (ui_anim): the value halves its
// distance to its target sixty times a second.
ANIM_RATE :: 60 * math.LN2

// As RAD's UI_AnimParams: where a new (or reset) value starts, how fast it
// approaches its target (k * ln 2: it halves its distance k times a second,
// RAD's 1 - 2^(-k dt) a frame; 0 is RAD's default, 60), and how near it lands
// on the target (0 is RAD's 0.005).
Animation_Params :: struct {
	initial: f32,
	rate:    f32,
	epsilon: f32,
	reset:   bool,
}

Animation_Row :: struct {
	key:                      Key,
	current, target:          f32,
	rate, epsilon:            f32,
	last_touched_build_index: u64,
}

Animation_Storage :: struct {
	rows:             [dynamic]Animation_Row,
	row_index_by_key: map[Key]u32,
}

animation_storage_make :: proc() -> Animation_Storage {
	return {rows = make([dynamic]Animation_Row), row_index_by_key = make(map[Key]u32)}
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

// anim_f32 returns persistent keyed animation state, as RAD's ui_anim: new
// or reappearing keys (and a reset) start at params.initial; build_end moves
// touched rows toward their target, landing on it within epsilon.
anim_f32 :: proc(s: ^State, key: Key, target: f32, params: Animation_Params = {}) -> f32 {
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
	if row_is_new || reappeared || params.reset do row.current = params.initial
	row.target = target
	row.rate = params.rate > 0 ? params.rate : ANIM_RATE
	row.epsilon = params.epsilon > 0 ? params.epsilon : 0.005
	if abs(row.current - row.target) < row.epsilon do row.current = row.target
	row.last_touched_build_index = s.build_index
	return row.current
}

animations_advance :: proc(s: ^State) {
	for &row in s.animations.rows {
		if row.last_touched_build_index != s.build_index do continue
		row.current = animation.approach(row.current, row.target, row.rate, s.p.frame_dt)
		if abs(row.current - row.target) > row.epsilon {s.is_animating = true} else {row.current = row.target}
	}
}
