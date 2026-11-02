package onimite_app

import "core:strings"

// The one matcher the lister and the Watch's filter use: RAD Debugger's
// fuzzy_match_find (base/base_strings.c:2737), as onib's (workflow/fuzzy.odin).
// A query is parts split on spaces; each part matches where it first appears
// in the label as a substring, ignoring case and which way a slash leans,
// outside the places earlier parts took. A label matches when every part
// does; an empty query matches everything. Nothing is ranked: rows keep
// their collection's order, as RAD's do.
Fuzzy_Range :: struct {
	first, last: int, // bytes of the label
}

// Whether `label` matches `query`, and with `ranges` where each part matched.
fuzzy_find :: proc(label, query: string, ranges: ^[dynamic]Fuzzy_Range = nil) -> bool {
	taken := make([dynamic]Fuzzy_Range, context.temp_allocator)
	rest := query
	for part in strings.fields_iterator(&rest) {
		at := find_part(label, part, 0)
		for at >= 0 {
			inside := -1
			for r in taken {if r.first <= at && at < r.last do inside = r.last}
			if inside < 0 do break
			at = find_part(label, part, inside)
		}
		if at < 0 do return false
		append(&taken, Fuzzy_Range{at, at + len(part)})
	}
	if ranges != nil do append(ranges, ..taken[:])
	return true
}

// Where `part` first lies in `label` at or after `from`, ignoring case and
// slash direction; -1 when it doesn't.
find_part :: proc(label, part: string, from: int) -> int {
	fold :: proc(c: u8) -> u8 {
		if c >= 'A' && c <= 'Z' do return c + ('a' - 'A')
		return c == '\\' ? '/' : c
	}
	for i := from; i + len(part) <= len(label); i += 1 {
		j := 0
		for j < len(part) && fold(label[i + j]) == fold(part[j]) do j += 1
		if j == len(part) do return i
	}
	return -1
}
