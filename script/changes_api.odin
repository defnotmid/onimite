package onimite_script

import "core:c"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import lua "vendor:lua/5.4"

// Rows that know when they changed, for a board fed by a data file that is
// replaced while it plays (`preview --live`):
//
//     local board = json_decode(io.open(SCRIPT_DIR .. "/flights.json"):read("a"))
//     local deps = track_changes("departures", board.departures, { key = "flight" })
//     -- deps[i].changed_at: when that row last changed (f.now's clock)
//     -- deps[i].before:     the row as it was before that change (nil: new)
//
// A row is matched with the previous load's row of the same `key` (the
// n-th of a key with the n-th, when a key repeats), or without `key` with
// the row at the same position. A row that differs from its match, or has
// none, changed at the load's moment (Load_Clock.at); one that doesn't
// keeps its match's stamp and `before`. Only the preview's reloads carry
// rows to the next load; any other load finds every row new, changed at
// the video's first frame.

// The clock a load sees, on the wall clock (seconds since 1970, UTC):
// `start` at the video's first frame (Video.now), `at` the load's own
// moment; `rows` is what track_changes stamped in the load before (the
// preview's last good load), nil for none.
Load_Clock :: struct {
	start, at: f64,
	rows:      ^Change_Memory,
}

// The rows track_changes stamped in one load: per list its name and its
// range of `rows`; per row its key ("" for a position), its value's hash,
// the value and the one before its last change frozen (in `arena`), and
// when that change was.
Change_Memory :: struct {
	lists: [dynamic]Change_List,
	rows:  [dynamic]Change_Row,
	arena: virtual.Arena,
}

Change_List :: struct {
	name:         string,
	first, count: int,
}

Change_Row :: struct {
	key:        string,
	hash:       u64,
	value:      Shared_Value,
	before:     Shared_Value,
	has_before: bool,
	changed_at: f64,
}

change_memory_destroy :: proc(m: ^Change_Memory) {
	delete(m.lists)
	delete(m.rows)
	virtual.arena_destroy(&m.arena)
	m^ = {}
}

// What the load stamped, for the next load's Load_Clock.rows; the script
// keeps none of it.
change_memory_take :: proc(s: ^Script) -> Change_Memory {
	m := s.changes
	s.changes = {}
	s.clock.rows = nil
	return m
}

// track_changes(name, list [, { key = field }]) -> list: stamps each row
// (a table) with `changed_at` and `before` (see above). Load only.
@(private)
l_track_changes :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	name := string(lua.L_checkstring(L, 1))
	lua.L_checktype(L, 2, i32(lua.Type.TABLE))
	key_field: cstring
	if !lua.isnoneornil(L, 3) {
		lua.L_checktype(L, 3, i32(lua.Type.TABLE))
		fields_begin(L, 3)
		if field(L, 3, "key") != c.int(lua.Type.NIL) {
			key_field = strings.clone_to_cstring(string(lua.L_checkstring(L, -1)), context.temp_allocator)
		}
		lua.pop(L, 1)
		fields_end(L, s, 3, "track_changes")
	}
	m := &s.changes
	for l in m.lists {
		if l.name == name {
			lua.L_error(L, "track_changes(%s): called twice in one load", lua.L_checkstring(L, 1))
		}
	}
	before := previous_list(s.clock.rows, name)
	// The previous rows by key (keyed lists), the keys seen so far here (a
	// repeated key is matched by its occurrence).
	by_key := make(map[string]int, context.temp_allocator)
	seen := make(map[string]int, context.temp_allocator)
	if key_field != nil {
		for r, i in before {
			by_key[r.key] = i
		}
	}
	alloc := virtual.arena_allocator(&m.arena)
	first := len(m.rows)
	n := int(lua.rawlen(L, 2))
	lua.L_checkstack(L, 8, "track_changes")
	for i in 1 ..= n {
		lua.rawgeti(L, 2, lua.Integer(i))
		row := lua.gettop(L)
		if !lua.istable(L, row) {
			lua.L_error(L, "track_changes(%s): row %d is a %s; rows are tables", lua.L_checkstring(L, 1), c.int(i), lua.L_typename(L, row))
		}
		for stamp in ([?]cstring{"changed_at", "before"}) {
			if lua.getfield(L, row, stamp) != c.int(lua.Type.NIL) {
				lua.L_error(L, "track_changes(%s): row %d already has %s, which track_changes sets", lua.L_checkstring(L, 1), c.int(i), stamp)
			}
			lua.pop(L, 1)
		}
		key := ""
		if key_field != nil {
			if t := lua.getfield(L, row, key_field); t != c.int(lua.Type.STRING) && t != c.int(lua.Type.NUMBER) {
				lua.L_error(L, "track_changes(%s): row %d has no %s (a string or number) to match it by", lua.L_checkstring(L, 1), c.int(i), key_field)
			}
			// a copy: tolstring turns a number into a string in place
			lua.pushvalue(L, -1)
			key = strings.clone(string(lua.tostring(L, -1)), context.temp_allocator)
			lua.pop(L, 2)
			if k := seen[key]; k > 0 {
				seen[key] = k + 1
				key = fmt.tprintf("%s\x00%d", key, k)
			} else {
				seen[key] = 1
			}
		}
		value := freeze_row(L, s, row, i)
		h := frozen_hash(&value)
		match := -1
		if key_field != nil {
			match = by_key[key] or_else -1
		} else if i - 1 < len(before) {
			match = i - 1
		}
		out := Change_Row {
			key        = strings.clone(key, alloc),
			hash       = h,
			value      = frozen_clone(value, alloc),
			changed_at = s.clock.at,
		}
		if match >= 0 {
			was := &before[match]
			if was.hash == h {
				out.changed_at, out.has_before = was.changed_at, was.has_before
				if was.has_before {
					out.before = frozen_clone(was.before, alloc)
				}
			} else {
				out.before, out.has_before = frozen_clone(was.value, alloc), true
			}
		}
		append(&m.rows, out)
		lua.pushnumber(L, lua.Number(out.changed_at))
		lua.setfield(L, row, "changed_at")
		if out.has_before {
			thaw(L, &m.rows[len(m.rows) - 1].before)
			lua.setfield(L, row, "before")
		}
		lua.settop(L, row - 1)
	}
	append(&m.lists, Change_List{name = strings.clone(name, alloc), first = first, count = n})
	lua.settop(L, 2)
	return 1
}

// The rows the list `name` had in `m` (none without it).
@(private = "file")
previous_list :: proc(m: ^Change_Memory, name: string) -> []Change_Row {
	if m == nil {
		return nil
	}
	for l in m.lists {
		if l.name == name {
			return m.rows[l.first:][:l.count]
		}
	}
	return nil
}

// The row at `row` frozen (temp memory); a Lua error when it holds what a
// later load can't rebuild (functions, handles).
@(private = "file")
freeze_row :: proc(L: ^lua.State, s: ^Script, row: c.int, i: int) -> Shared_Value {
	f: Freezer
	f.tables.allocator, f.items.allocator, f.bytes.allocator = context.temp_allocator, context.temp_allocator, context.temp_allocator
	bad: cstring
	if !freeze(L, &f, row) {
		bad = f.bad
	}
	for it in f.items {
		if it.kind == .Pointer {
			bad = "handle"
		}
	}
	if bad != nil {
		lua.L_error(L, "track_changes(%s): row %d holds a %s; rows are data (strings, numbers, booleans, tables)", lua.L_checkstring(L, 1), c.int(i), bad)
	}
	return {root = f.root, tables = f.tables[:], items = f.items[:], bytes = f.bytes[:]}
}

@(private = "file")
frozen_clone :: proc(v: Shared_Value, alloc: mem.Allocator) -> Shared_Value {
	return {root = v.root, tables = clone_slice(v.tables, alloc), items = clone_slice(v.items, alloc), bytes = clone_slice(v.bytes, alloc)}
}

// A hash of the value that two equal values share whatever order their
// tables' keys froze in (a sum over each table's pairs). Tables are hashed
// from the last frozen to the first: a table's own tables come after it;
// one met again (shared, or a cycle) counts as a mark, not its contents.
@(private = "file")
frozen_hash :: proc(v: ^Shared_Value) -> u64 {
	tables := make([]u64, len(v.tables), context.temp_allocator)
	#reverse for t, i in v.tables {
		sum: u64
		pairs := v.items[t.first:][:2 * t.pairs]
		for k := 0; k < len(pairs); k += 2 {
			sum += mix64(item_hash(v, pairs[k], tables, i) * 0x9e3779b97f4a7c15 + item_hash(v, pairs[k + 1], tables, i))
		}
		tables[i] = mix64(sum ~ u64(t.pairs))
	}
	return item_hash(v, v.root, tables, -1)
}

@(private = "file")
item_hash :: proc(v: ^Shared_Value, it: Shared_Item, tables: []u64, at: int) -> u64 {
	#partial switch it.kind {
	case .String:
		return mix64(hash.fnv64a(v.bytes[it.a:][:it.b]) + u64(Shared_Kind.String))
	case .Table:
		if int(it.a) > at {
			return tables[it.a]
		}
		return mix64(u64(Shared_Kind.Table))
	}
	return mix64(it.bits * 31 + u64(it.kind))
}

// splitmix64's finalizer.
@(private = "file")
mix64 :: proc(x: u64) -> u64 {
	x := x
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	return x ~ (x >> 31)
}
