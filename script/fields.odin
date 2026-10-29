package onimite_script

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import om "../onimite"
import lua "vendor:lua/5.4"

// Unused fields: a misspelled option (`fil = "#f00"`) reads as nothing in
// Lua, so a binding notes the keys it reads from its option table
// (`fields_begin`, then every read through `field`) and `fields_end`
// reports the string keys it never read, with the closest read key as a
// suggestion. The keys a binding asks for are its vocabulary: aliases count,
// and no list is kept beside the code.

@(private)
FIELD_LOG_MAX :: 96

@(private)
Field_Log :: struct {
	table: rawptr, // the table being checked (lua.topointer), nil when none
	keys:  [FIELD_LOG_MAX]string, // views of the bindings' key literals (or interned Lua strings)
	n:     int,
}

// One per thread: a Lua state runs on one thread at a time, and a binding
// checks its table before it calls back into Lua.
@(private, thread_local)
field_log: Field_Log

// Starts noting the keys read from the table at `t`.
@(private)
fields_begin :: proc(L: ^lua.State, t: c.int) {
	field_log.table = lua.topointer(L, t)
	field_log.n = 0
}

// lua.getfield that notes `key` when `t` is the table being checked.
@(private)
field :: proc(L: ^lua.State, t: c.int, key: cstring) -> c.int {
	if field_log.table != nil && field_log.n < FIELD_LOG_MAX && lua.topointer(L, t) == field_log.table {
		field_log.keys[field_log.n] = string(key)
		field_log.n += 1
	}
	return lua.getfield(L, t, key)
}

// Notes `key` as read without reading it (a field another layer uses).
@(private)
field_used :: proc(key: cstring) {
	if field_log.table != nil && field_log.n < FIELD_LOG_MAX {
		field_log.keys[field_log.n] = string(key)
		field_log.n += 1
	}
}

// Reports the string keys of the table at `t` that were not read since
// `fields_begin`, as `call.key`, and stops noting. It runs on every node of
// every frame, so the usual case (every key read) walks the keys in place;
// only a table with an unread key is listed, sorted and reported.
@(private)
fields_end :: proc(L: ^lua.State, s: ^Script, at: c.int, call: string) {
	defer field_log.table = nil
	if field_log.table == nil || field_log.n >= FIELD_LOG_MAX {
		return
	}
	t := lua.absindex(L, at)
	lua.pushnil(L)
	for lua.next(L, t) != 0 {
		unread := false
		if lua.type(L, -2) == .STRING {
			n: c.size_t
			p := lua.tolstring(L, -2, &n)
			unread = !field_was_read(string((cast([^]u8)p)[:n]))
		}
		lua.pop(L, 1)
		if unread {
			lua.pop(L, 1)
			for key in sorted_keys(L, t) {
				if !field_was_read(key) {
					report_unused(L, s, call, key)
				}
			}
			return
		}
	}
}

// The string keys of the table at `t`, sorted (temp memory). A Lua table's
// own order changes from run to run (string hashes are seeded per state),
// so whatever a script names by key is read, reported and listed in this
// one.
@(private)
sorted_keys :: proc(L: ^lua.State, t: c.int) -> []string {
	t := lua.absindex(L, t)
	keys := make([dynamic]string, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, t) != 0 {
		if lua.type(L, -2) == .STRING {
			n: c.size_t
			p := lua.tolstring(L, -2, &n)
			append(&keys, strings.clone(string((cast([^]u8)p)[:n]), context.temp_allocator))
		}
		lua.pop(L, 1)
	}
	slice.sort(keys[:])
	return keys[:]
}

// Pushes `t[key]` (raw) for the table at `t`.
@(private)
push_key :: proc(L: ^lua.State, t: c.int, key: string) {
	t := lua.absindex(L, t)
	lua.pushlstring(L, cstring(raw_data(key)), c.size_t(len(key)))
	lua.rawget(L, t)
}

@(private)
field_was_read :: proc(key: string) -> bool {
	for k in field_log.keys[:field_log.n] {
		if k == key {
			return true
		}
	}
	return false
}

// The read key closest to `key`: one it begins (`gain` for `gain_db`), else
// the nearest within a third of its length in edits (at least one; a swap
// of neighbours is one edit).
@(private)
closest_key :: proc(key: string, candidates: []string) -> string {
	for k in candidates {
		if len(key) >= 3 && strings.has_prefix(k, key) {
			return k
		}
	}
	best, best_d := "", max(1, len(key) / 3) + 1
	for k in candidates {
		d := edit_distance(key, k)
		if d < best_d {
			best, best_d = k, d
		}
	}
	return best
}

// Optimal string alignment distance: insertions, deletions, substitutions
// and swaps of neighbouring bytes.
@(private)
edit_distance :: proc(a, b: string) -> int {
	if len(b) > 63 {
		return len(a) + len(b)
	}
	rows: [3][64]int // two rows back, one back, current
	for j in 0 ..= len(b) {
		rows[1][j] = j
	}
	for i in 1 ..= len(a) {
		cur := &rows[(i + 1) % 3]
		prev := &rows[i % 3]
		prev2 := &rows[(i + 2) % 3]
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
			if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
				cur[j] = min(cur[j], prev2[j - 2] + 1)
			}
		}
	}
	return rows[(len(a) + 1) % 3][len(b)]
}

@(private)
report_unused :: proc(L: ^lua.State, s: ^Script, call, key: string) {
	report_warning(L, s, {
		code = .Unused_Field,
		a = fmt.tprintf("%s.%s", call, key),
		b = closest_key(key, field_log.keys[:field_log.n]),
	})
}

// The script position of the Lua code that called the binding in
// progress ("video.lua:12"), in temp memory: the first Lua frame up the
// stack outside the standard library, so a warning from `stagger` or
// `captions` names the script's line.
@(private)
caller_where :: proc(L: ^lua.State) -> string {
	at, _ := caller_where_via(L)
	return at
}

// caller_where, and the first script line up the stack in another file: the
// call into a helper (look.lua drew it, scenes/race.lua:10 asked).
@(private)
caller_where_via :: proc(L: ^lua.State) -> (at, via: string) {
	ar: lua.Debug
	first, at_file := "", ""
	for level: c.int = 1; lua.getstack(L, level, &ar) != 0; level += 1 {
		lua.getinfo(L, "Sl", &ar)
		if ar.currentline <= 0 || ar.source == nil {
			continue
		}
		src := string(ar.source)
		if strings.has_prefix(src, "@") || strings.has_prefix(src, "=") {
			src = src[1:]
		}
		if src == "std.lua" {
			if first == "" {
				first = fmt.tprintf("%s:%d", src, ar.currentline)
			}
			continue
		}
		pos := fmt.tprintf("%s:%d", src, ar.currentline)
		if at == "" {
			at, at_file = pos, src
		} else if src != at_file {
			return at, pos
		}
	}
	if at == "" {
		at = first
	}
	return
}

// Reports a problem about the calling script line (`d.name` is set to
// it): to the frame being rendered, else (at load) to `s.load_problems`.
// Repeats within a frame or a load are dropped.
@(private)
report_warning :: proc(L: ^lua.State, s: ^Script, d: om.Diagnostic, severity := om.Severity.Warning) {
	d := d
	d.name = caller_where(L)
	report_problem(s, d, severity)
}

// Reports a problem about the script line `d.name` names, as
// report_warning does.
@(private)
report_problem :: proc(s: ^Script, d: om.Diagnostic, severity := om.Severity.Warning) {
	if s.ctx != nil {
		for e in s.ctx.diagnostics {
			if same_problem(e, d) {
				return
			}
		}
		om.report(s.ctx, severity, d)
		return
	}
	load_problem(s, severity, d)
}

// Keeps a problem the load found in `s.load_problems` (strings cloned),
// unless it is there already: every command prints them and the findings
// list them "at load".
@(private)
load_problem :: proc(s: ^Script, severity: om.Severity, d: om.Diagnostic) {
	for e in s.load_problems {
		if same_problem(e, d) {
			return
		}
	}
	d := d
	d.severity = severity
	d.name = strings.clone(d.name)
	d.a = strings.clone(d.a)
	d.b = strings.clone(d.b)
	append(&s.load_problems, d)
}

// Raises a Lua error at load with the text a frame would report for `d`,
// after `fn: ` (a load can not go on without what it asked for).
@(private)
load_error :: proc(L: ^lua.State, fn: cstring, d: om.Diagnostic) {
	message := om.diagnostic_message(d, context.temp_allocator)
	lua.L_error(L, "%s: %s", fn, strings.clone_to_cstring(message, context.temp_allocator))
}

// One problem at one place: its code, line and subject, and what groups it
// (diagnostic_key: two of odawg's findings on one song are two problems).
@(private = "file")
same_problem :: proc(x, y: om.Diagnostic) -> bool {
	return x.code == y.code && x.name == y.name && x.a == y.a && om.diagnostic_key(x, context.temp_allocator) == om.diagnostic_key(y, context.temp_allocator)
}

// check_fields(t, name, keys): the standard library's check of an option
// table against the keys its function reads.
@(private)
l_check_fields :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	if !lua.istable(L, 1) {
		return 0
	}
	lua.L_checktype(L, 3, i32(lua.Type.TABLE))
	fields_begin(L, 1)
	n := int(lua.rawlen(L, 3))
	for i in 1 ..= n {
		lua.rawgeti(L, 3, lua.Integer(i))
		// Interned by Lua and kept alive by the keys table for the check.
		field_used(lua.tostring(L, -1))
		lua.pop(L, 1)
	}
	fields_end(L, s, 1, string(lua.L_checkstring(L, 2)))
	return 0
}


// Checks a table nested in the one being checked (an audio track inside
// video{}): `fields_push` starts it and returns the outer log, which
// `fields_pop` reports the inner table against and then restores.
@(private)
fields_push :: proc(L: ^lua.State, t: c.int) -> Field_Log {
	outer := field_log
	fields_begin(L, t)
	return outer
}

@(private)
fields_pop :: proc(L: ^lua.State, s: ^Script, t: c.int, call: string, outer: Field_Log) {
	fields_end(L, s, t, call)
	field_log = outer
}
