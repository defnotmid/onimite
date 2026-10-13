package ui

import "core:testing"
import platform "../platform"

// A keyed box starts each frame from last frame's rect; a key built twice
// in a frame is transient the second time; keys not built are forgotten.
@(test)
test_box_memory :: proc(t: ^testing.T) {
	p: platform.Platform
	p.width, p.height = 200, 100
	s: State
	init(&s, nil, &p, nil)
	defer destroy(&s)
	frame :: proc(s: ^State, twice: bool, with_b: bool) -> (a: ^Box, dup: ^Box) {
		build_begin(s)
		set_next_pref_width(s, px(40))
		set_next_pref_height(s, px(20))
		a = build_box(s, {}, "###a")
		if twice {
			set_next_pref_width(s, px(10))
			set_next_pref_height(s, px(10))
			dup = build_box(s, {}, "###a")
		}
		if with_b {
			set_next_pref_width(s, px(30))
			set_next_pref_height(s, px(20))
			build_box(s, {}, "###b")
		}
		build_end(s)
		return
	}
	defer free_all(context.temp_allocator)
	a, _ := frame(&s, false, true)
	testing.expect_value(t, a.rect.max, [2]f32{40, 20})
	// The root, a and b.
	testing.expect_value(t, len(s.memories), 3)
	a2, dup := frame(&s, true, false)
	// The same row; the second box of the key has none.
	testing.expect_value(t, a2.memory, a.memory)
	testing.expect_value(t, dup.memory, -1)
	testing.expect_value(t, len(s.memories), 2)
	testing.expect_value(t, len(s.memory_of_key), 2)
	// Built with last frame's rect (layout sets this frame's at build_end).
	build_begin(&s)
	set_next_pref_width(&s, px(5))
	set_next_pref_height(&s, px(5))
	again := build_box(&s, {}, "###a")
	testing.expect_value(t, again.rect.max, [2]f32{40, 20})
	build_end(&s)
}
