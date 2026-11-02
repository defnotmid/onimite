package ui

import "core:strings"

// What one input row does to a line of text, as RAD Debugger's UI_TxtOp: the
// byte range to replace and what with, what to copy, and where the cursor and
// mark go. Offsets are into the whole text.
Text_Op :: struct {
	replace:      string,
	copy:         string,
	range:        [2]int,
	cursor, mark: int,
}

// As RAD's ui_single_line_txt_op_from_event: a Navigate, Edit or Text row
// applied to `line`, the bytes `line_range` of a text (a field's whole text),
// with the cursor and mark as offsets into that text. One deviation, asked
// for: a Char step is a whole UTF-8 character, as RAD's own TODO says it
// should be (it steps bytes).
text_op_from_action :: proc(a: Action_Row, line: string, line_range: [2]int, cursor, mark: int) -> Text_Op {
	next_cursor, next_mark := cursor, mark
	range: [2]int
	replace, copied: string
	delta := a.delta
	at := cursor - line_range[0]
	// The unit's delta in bytes.
	switch a.delta_unit {
	case .Null:
	case .Char:
		to := at
		for _ in 0 ..< abs(delta.x) {
			if delta.x < 0 && to > 0 {to -= 1; for to > 0 && line[to] & 0xC0 == 0x80 do to -= 1}
			if delta.x > 0 && to < len(line) {to += 1; for to < len(line) && line[to] & 0xC0 == 0x80 do to += 1}
		}
		delta.x = i32(to - at)
	case .Word:
		delta.x = i32(scanned_column_from_column(line, at + 1, delta.x > 0) - 1 - at)
	case .Line, .Whole, .Page:
		first_text := 0
		for i in 0 ..< len(line) {if !char_is_space(line[i]) {first_text = i; break}}
		home := at == first_text ? 0 : first_text
		delta.x = i32(delta.x > 0 ? len(line) - at : home - at)
	}
	// With a selection, some moves only collapse it.
	if cursor != mark && .Zero_Delta_On_Select in a.flags do delta = {}
	if cursor == mark || .Zero_Delta_On_Select not_in a.flags {
		delta.x = max(delta.x, -i32(next_cursor - line_range[0]))
		delta.x = min(delta.x, i32(line_range[1] - next_cursor))
		next_cursor += int(delta.x)
	}
	if .Cap_At_Line in a.flags do next_cursor = clamp(next_cursor, line_range[0], line_range[1] + 1)
	if cursor != mark && .Pick_Select_Side in a.flags {
		if a.delta.x < 0 || a.delta.y < 0 {
			next_cursor = min(cursor, mark); next_mark = next_cursor
		} else if a.delta.x > 0 || a.delta.y > 0 {
			next_cursor = max(cursor, mark); next_mark = next_cursor
		}
	}
	if .Copy in a.flags do copied = line[min(cursor, mark) - line_range[0]:max(cursor, mark) - line_range[0]]
	if .Delete in a.flags {
		range = {min(next_cursor, next_mark), max(next_cursor, next_mark)}
		next_cursor = range[0]; next_mark = range[0]
	}
	if .Keep_Mark not_in a.flags do next_mark = next_cursor
	if len(a.text) != 0 {
		range = {min(cursor, mark), max(cursor, mark)}
		replace = a.text
		next_cursor = range[0] + len(a.text); next_mark = next_cursor
	}
	return {replace = replace, copy = copied, range = range, cursor = next_cursor, mark = next_mark}
}

// A text op's replacement made in a byte buffer, as RAD's
// ui_push_string_replace_range (in place).
text_replace_range :: proc(buf: ^[dynamic]u8, range: [2]int, replace: string) {
	lo := range[0] > len(buf) ? 0 : range[0]
	hi := min(range[1], len(buf))
	tail := strings.clone(string(buf[hi:]), context.temp_allocator)
	resize(buf, lo)
	append(buf, replace)
	append(buf, tail)
}

// As RAD's ui_scanned_column_from_column: from a 1-based column, the column
// a word move reaches, scanning toward `forward`'s side. A word is a run of
// ASCII letters, digits and '_'; spaces before it are crossed with it.
@(private)
scanned_column_from_column :: proc(s: string, start: int, forward: bool) -> int {
	column := start
	delta := forward ? 1 : -1
	found_text, found_non_space := false, false
	for col := start + (delta < 0 ? delta : 0); 1 <= col && col <= len(s) + 1; col += delta {
		b := col <= len(s) ? s[col - 1] : 0
		non_space := !char_is_space(b)
		name := b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_'
		if !forward && col == 1 || forward && col == len(s) + 1 || found_non_space && !non_space || found_text && !name {
			column = col + (!forward && col != 1 ? 1 : 0)
			break
		} else if !found_text && name {
			found_text = true
		} else if !found_non_space && non_space {
			found_non_space = true
		}
	}
	return column
}

@(private)
char_is_space :: proc(b: u8) -> bool {return b == ' ' || b == '\n' || b == '\t' || b == '\r' || b == '\f' || b == '\v'}
