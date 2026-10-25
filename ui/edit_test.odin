package ui

import "../platform"
import "core:testing"

@(test)
test_line_edit_inserts_and_deletes_at_utf8_cursor :: proc(t: ^testing.T) {
	p := platform.Platform {
		width  = 800,
		height = 600,
	}
	s: State; init(&s, nil, &p, nil); defer destroy(&s)
	buf := make([dynamic]u8); defer delete(buf)
	append(&buf, "aλc")
	cursor := len(buf)
	build_begin(&s)
	first := line_edit(&s, &buf, &cursor); s.keyboard_focus = first.box.key
	build_begin(&s)
	append(
		&s.actions.rows,
		Action_Row{kind = .Navigate, delta = {-1, 0}},
		Action_Row{kind = .Text, text = 'b'},
	)
	line_edit(&s, &buf, &cursor)
	testing.expect_value(t, string(buf[:]), "aλbc")
	build_begin(&s)
	append(
		&s.actions.rows,
		Action_Row{kind = .Edit, delta = {-1, 0}},
		Action_Row{kind = .Edit, delta = {-1, 0}},
	)
	line_edit(&s, &buf, &cursor)
	testing.expect_value(t, string(buf[:]), "ac")
	testing.expect_value(t, cursor, 1)
}
