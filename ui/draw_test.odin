package ui

import "../platform"
import "../render"
import "core:testing"

@(test)
test_deferred_boxes_keep_their_draw_scope :: proc(t: ^testing.T) {
	p := platform.Platform {
		width  = 800,
		height = 600,
	}
	r: render.Renderer
	defer delete(r.cmds); defer delete(r.rect_insts)
	s: State; init(&s, &r, &p, nil); defer destroy(&s)
	build_begin(&s)
	s.draw_scope = 41
	a := build_box(&s, {.Draw_Background}, "a")
	a.rect = {{0, 0}, {100, 100}}; a.opacity = 1
	s.draw_scope = 42
	b := build_box(&s, {.Draw_Background}, "b")
	b.rect = {{100, 0}, {200, 100}}; b.opacity = 1
	s.draw_scope = 0
	draw_box(&s, a, 0); draw_box(&s, b, 0)
	testing.expect(t, len(r.cmds) == 2 && r.cmds[0].scope == 41 && r.cmds[1].scope == 42)
	testing.expect_value(t, r.scope, u32(0))
	// Reusing a keyed box in a later frame must replace the old output owner.
	build_begin(&s)
	s.draw_scope = 43
	a = build_box(&s, {.Draw_Background}, "a")
	testing.expect_value(t, a.draw_scope, u32(43))
}
