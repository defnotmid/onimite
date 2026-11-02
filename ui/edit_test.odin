package ui

import "../platform"
import "../render"
import "core:testing"

// A field edits through RAD's text op: whole UTF-8 characters, the selection
// a typed character replaces, Shift moves keeping the mark, word moves and
// deletes, and Home/End.
@(test)
test_line_edit_edits_through_rad_text_ops :: proc(t: ^testing.T) {
	p := platform.Platform{width = 800, height = 600}
	font, ok := render.font_load(#load("../assets/fonts/JetBrainsMono-Regular.ttf")); assert(ok); defer render.font_unload(&font)
	s: State; init(&s, nil, &p, &font); defer destroy(&s)
	buf := make([dynamic]u8); defer delete(buf)
	append(&buf, "aλc")
	cursor, mark := len(buf), len(buf)
	// The field is being edited: its focus is active, as a focused view's.
	frame :: proc(s: ^State, buf: ^[dynamic]u8, cursor, mark: ^int, rows: ..Action_Row) {
		action_storage_clear(&s.actions)
		append(&s.actions.rows, ..rows)
		build_begin(s)
		push_focus(s, .On)
		line_edit(s, buf, cursor, mark)
		pop_focus(s)
		build_end(s)
	}
	left :: Action_Row{kind = .Navigate, delta_unit = .Char, delta = {-1, 0}, flags = {.Pick_Select_Side, .Zero_Delta_On_Select, .Explicit_Directional}}
	backspace :: Action_Row{kind = .Edit, delta_unit = .Char, delta = {-1, 0}, flags = {.Delete, .Zero_Delta_On_Select}}
	frame(&s, &buf, &cursor, &mark, left, Action_Row{kind = .Text, text = "b"})
	testing.expect_value(t, string(buf[:]), "aλbc")
	frame(&s, &buf, &cursor, &mark, backspace, backspace)
	testing.expect_value(t, string(buf[:]), "ac")
	testing.expect_value(t, cursor, 1)
	// Shift+Left keeps the mark; typing replaces the selection.
	frame(&s, &buf, &cursor, &mark, Action_Row{kind = .Navigate, delta_unit = .Char, delta = {-1, 0}, flags = {.Keep_Mark}})
	testing.expect(t, cursor == 0 && mark == 1, "Shift+Left selects")
	frame(&s, &buf, &cursor, &mark, Action_Row{kind = .Text, text = "xy"})
	testing.expect_value(t, string(buf[:]), "xyc")
	// Focus hot but not being edited, typing starts an edit with everything
	// selected (RAD's rd_cell): the first character replaces it.
	action_storage_clear(&s.actions)
	append(&s.actions.rows, Action_Row{kind = .Text, text = "q"})
	build_begin(&s)
	push_focus_hot(&s, .On); push_focus_active(&s, .Off)
	line_edit(&s, &buf, &cursor, &mark)
	pop_focus(&s)
	build_end(&s)
	testing.expect_value(t, string(buf[:]), "q")
	// A vertical step is left for a list.
	frame(&s, &buf, &cursor, &mark, Action_Row{kind = .Navigate, delta_unit = .Char, delta = {0, 1}})
	testing.expect_value(t, action_navigation_delta(&s), [2]i32{0, 1})
}

// RAD's text op on its own: word moves, Home's first-text toggle, deleting a
// word, and what a copy takes.
@(test)
test_text_op_word_home_delete_copy :: proc(t: ^testing.T) {
	line := "  foo_bar baz"
	end := len(line)
	word_left := text_op_from_action({kind = .Navigate, delta_unit = .Word, delta = {-1, 0}}, line, {0, end}, end, end)
	testing.expect_value(t, word_left.cursor, 10) // before "baz"
	word_right := text_op_from_action({kind = .Navigate, delta_unit = .Word, delta = {1, 0}}, line, {0, end}, 0, 0)
	testing.expect_value(t, word_right.cursor, 9) // past "  foo_bar"
	home := text_op_from_action({kind = .Navigate, delta_unit = .Line, delta = {-1, 0}}, line, {0, end}, end, end)
	testing.expect_value(t, home.cursor, 2) // the first text
	home_again := text_op_from_action({kind = .Navigate, delta_unit = .Line, delta = {-1, 0}}, line, {0, end}, 2, 2)
	testing.expect_value(t, home_again.cursor, 0) // then the line's start
	chunk := text_op_from_action({kind = .Edit, delta_unit = .Word, delta = {-1, 0}, flags = {.Delete, .Zero_Delta_On_Select}}, line, {0, end}, end, end)
	testing.expect_value(t, chunk.range, [2]int{10, end})
	copied := text_op_from_action({kind = .Edit, flags = {.Copy, .Keep_Mark}}, line, {0, end}, 2, 5)
	testing.expect(t, copied.copy == "foo" && copied.cursor == 2 && copied.mark == 5, "copy keeps the selection")
}
