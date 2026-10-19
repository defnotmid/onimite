package onimite_script

import "core:c"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import om "../onimite"
import vg "deps:ovg"
import lua "vendor:lua/5.4"

// Load-time data made once and shared by the script states of one render
// (its frame builders each load the script into their own Lua state):
//
//     local ink = shared("ink", function()     -- runs once per render
//       local list = {}
//       for d in gunzip("ink.paths.gz"):gmatch("[^\n]+") do
//         list[#list + 1] = path_data(d)          -- parsed once, a handle
//       end
//       return list
//     end)
//     path { d = ink[i], fill = "#000" }
//
// `path_data` parses SVG path data into a `Path_Asset` (by content), and
// `shared` keeps a copy of a load-time value (tables, strings, numbers,
// booleans, path handles) that the other states rebuild instead of running
// the function again, so neither the source text nor the parsing is
// repeated per builder. Entries are only added, under `lock`; an asset
// never moves or changes once made, so renders read it without the lock.
// A script loaded without a `Shared` (the preview, single commands) makes
// its own.
Shared :: struct {
	lock:    sync.Mutex,
	// Path assets and frozen values (stable addresses).
	arena:   virtual.Arena,
	paths:   map[u64]^om.Path_Asset,
	// Prepared morphs by their two outlines, and the set of them (morph_at
	// checks its handle).
	morphs:  map[u64]^Shared_Morph,
	morph_set: map[^Shared_Morph]bool,
	values:  map[string]^Shared_Value,
	// Clips `audio_add` made from a function this render (by name).
	audio:   map[string]bool,
	// Lines `say` spoke (by name): their words and chunks in the arena (no
	// samples: those are in the media).
	lines:   map[string]^Said_Line,
	// Parse scratch (used under the lock).
	scratch: vg.Path,
}

// A Lua value as flat rows: tables in breadth-first order, each one's
// key/value pairs contiguous in `items` (keys at even offsets), strings in
// `bytes`. Table values refer to their table by index, so shared and cyclic
// references keep their identity.
@(private)
Shared_Value :: struct {
	root:   Shared_Item,
	tables: []Shared_Table,
	items:  []Shared_Item,
	bytes:  []u8,
}

@(private)
Shared_Table :: struct {
	first: u32,
	pairs: u32,
	// The length of its sequence part (a size hint).
	array: u32,
}

@(private)
Shared_Kind :: enum u8 {
	False,
	True,
	Integer,
	Number,
	String,
	Table,
	Pointer,
}

@(private)
Shared_Item :: struct {
	kind: Shared_Kind,
	// String: offset and length in `bytes`; table: its index.
	a, b: u32,
	// Integer, number (bits) or pointer.
	bits: u64,
}

shared_destroy :: proc(sh: ^Shared) {
	virtual.arena_destroy(&sh.arena)
	delete(sh.paths)
	delete(sh.morphs)
	delete(sh.morph_set)
	delete(sh.values)
	for name in sh.audio {
		delete(name)
	}
	delete(sh.audio)
	delete(sh.lines)
	vg.path_destroy(&sh.scratch)
	sh^ = {}
}

// The asset for path data `d`, parsed on first use; nil if `d` is invalid.
shared_path :: proc(sh: ^Shared, d: string) -> ^om.Path_Asset {
	key := hash.fnv64a(transmute([]u8)d)
	sync.guard(&sh.lock)
	if a, found := sh.paths[key]; found {
		return a
	}
	p := &sh.scratch
	vg.path_reset(p)
	if !vg.path_svg(p, d) {
		return nil
	}
	alloc := virtual.arena_allocator(&sh.arena)
	a := new(om.Path_Asset, alloc)
	a.verbs = make([]vg.Verb, len(p.verbs), alloc)
	a.coords = make([]vg.Vec2, len(p.coords), alloc)
	copy(a.verbs, p.verbs[:])
	copy(a.coords, p.coords[:])
	a.key = path_key(p, .Non_Zero)
	sh.paths[key] = a
	return a
}

// path_data(d) -> handle: SVG path data parsed once (shared by every frame
// builder, by content); `path{ d = handle }` draws it without parsing text.
@(private)
l_path_data :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	n: c.size_t
	p := lua.L_checkstring(L, 1, &n)
	a := shared_path(s.shared, string((cast([^]u8)p)[:n]))
	if a == nil {
		lua.L_error(L, "path_data: invalid path data")
	}
	lua.pushlightuserdata(L, a)
	return 1
}

// shared(name, build) -> value: `build()` runs once per render; every
// frame builder gets a copy of its result.
@(private)
l_shared :: proc "c" (L: ^lua.State) -> c.int {
	s := host(L)
	context = s.odin_context
	name := string(lua.L_checkstring(L, 1))
	lua.L_checktype(L, 2, i32(lua.Type.FUNCTION))
	sh := s.shared
	sync.lock(&sh.lock)
	v, found := sh.values[name]
	sync.unlock(&sh.lock)
	if found {
		thaw(L, v)
		return 1
	}
	lua.settop(L, 2)
	lua.call(L, 0, 1)
	f: Freezer
	if !freeze(L, &f, 2) {
		// The error unwinds past this frame's defers.
		freezer_destroy(&f)
		lua.L_error(L, "shared(%s): can not share a %s", lua.L_checkstring(L, 1), f.bad)
	}
	defer freezer_destroy(&f)
	sync.guard(&sh.lock)
	if name not_in sh.values {
		alloc := virtual.arena_allocator(&sh.arena)
		v = new(Shared_Value, alloc)
		v^ = {
			root   = f.root,
			tables = clone_slice(f.tables[:], alloc),
			items  = clone_slice(f.items[:], alloc),
			bytes  = clone_slice(f.bytes[:], alloc),
		}
		sh.values[strings.clone(name, alloc)] = v
	}
	// This state keeps the value it built.
	return 1
}

@(private = "file")
clone_slice :: proc(s: []$T, alloc: mem.Allocator) -> []T {
	out := make([]T, len(s), alloc)
	copy(out, s)
	return out
}

@(private = "file")
Freezer :: struct {
	root:   Shared_Item,
	tables: [dynamic]Shared_Table,
	items:  [dynamic]Shared_Item,
	bytes:  [dynamic]u8,
	// Lua tables (stack slots): table -> index, index + 1 -> table.
	memo:   c.int,
	queue:  c.int,
	// The type found that can not be shared.
	bad:    cstring,
}

@(private = "file")
freezer_destroy :: proc(f: ^Freezer) {
	delete(f.tables)
	delete(f.items)
	delete(f.bytes)
}

// Flattens the value at `at`; on failure `f.bad` names a type it can not
// share (functions, userdata, threads).
@(private = "file")
freeze :: proc(L: ^lua.State, f: ^Freezer, at: c.int) -> bool {
	idx := lua.absindex(L, at)
	lua.createtable(L, 0, 0)
	f.memo = lua.gettop(L)
	lua.createtable(L, 0, 0)
	f.queue = lua.gettop(L)
	defer lua.settop(L, f.memo - 1)
	f.root = freeze_item(L, f, idx) or_return
	for i := 0; i < len(f.tables); i += 1 {
		lua.rawgeti(L, f.queue, lua.Integer(i + 1))
		t := lua.gettop(L)
		first := len(f.items)
		lua.pushnil(L)
		for lua.next(L, t) != 0 {
			append(&f.items, freeze_item(L, f, t + 1) or_return)
			append(&f.items, freeze_item(L, f, t + 2) or_return)
			lua.pop(L, 1)
		}
		f.tables[i] = {u32(first), u32((len(f.items) - first) / 2), u32(lua.rawlen(L, t))}
		lua.pop(L, 1)
	}
	return true
}

@(private = "file")
freeze_item :: proc(L: ^lua.State, f: ^Freezer, idx: c.int) -> (it: Shared_Item, ok: bool) {
	#partial switch lua.type(L, idx) {
	case .BOOLEAN:
		it.kind = .True if lua.toboolean(L, idx) else .False
	case .NUMBER:
		if lua.isinteger(L, idx) {
			it = {kind = .Integer, bits = u64(i64(lua.tointeger(L, idx)))}
		} else {
			it = {kind = .Number, bits = transmute(u64)f64(lua.tonumber(L, idx))}
		}
	case .STRING:
		n: c.size_t
		p := lua.tolstring(L, idx, &n)
		it = {kind = .String, a = u32(len(f.bytes)), b = u32(n)}
		append(&f.bytes, ..(cast([^]u8)p)[:n])
	case .LIGHTUSERDATA:
		it = {kind = .Pointer, bits = u64(uintptr(lua.touserdata(L, idx)))}
	case .TABLE:
		lua.pushvalue(L, idx)
		if lua.rawget(L, f.memo) == c.int(lua.Type.NUMBER) {
			it = {kind = .Table, a = u32(lua.tointeger(L, -1))}
			lua.pop(L, 1)
			return it, true
		}
		lua.pop(L, 1)
		it = {kind = .Table, a = u32(len(f.tables))}
		append(&f.tables, Shared_Table{})
		lua.pushvalue(L, idx)
		lua.pushinteger(L, lua.Integer(it.a))
		lua.rawset(L, f.memo)
		lua.pushvalue(L, idx)
		lua.rawseti(L, f.queue, lua.Integer(it.a + 1))
	case:
		f.bad = lua.L_typename(L, idx)
		return {}, false
	}
	return it, true
}

// Pushes a copy of `v`: its tables made first, then filled.
@(private = "file")
thaw :: proc(L: ^lua.State, v: ^Shared_Value) {
	lua.L_checkstack(L, 8, "shared")
	lua.createtable(L, c.int(len(v.tables)), 0)
	refs := lua.gettop(L)
	for t, i in v.tables {
		lua.createtable(L, c.int(t.array), c.int(max(int(t.pairs) - int(t.array), 0)))
		lua.rawseti(L, refs, lua.Integer(i + 1))
	}
	for t, i in v.tables {
		lua.rawgeti(L, refs, lua.Integer(i + 1))
		pairs := v.items[t.first:][:2 * t.pairs]
		for k := 0; k < len(pairs); k += 2 {
			push_item(L, v, pairs[k], refs)
			push_item(L, v, pairs[k + 1], refs)
			lua.rawset(L, -3)
		}
		lua.pop(L, 1)
	}
	push_item(L, v, v.root, refs)
	lua.remove(L, refs)
}

@(private = "file")
push_item :: proc(L: ^lua.State, v: ^Shared_Value, it: Shared_Item, refs: c.int) {
	switch it.kind {
	case .False, .True:
		lua.pushboolean(L, it.kind == .True)
	case .Integer:
		lua.pushinteger(L, lua.Integer(i64(it.bits)))
	case .Number:
		lua.pushnumber(L, lua.Number(transmute(f64)it.bits))
	case .String:
		lua.pushlstring(L, cstring(raw_data(v.bytes[it.a:])), c.size_t(it.b))
	case .Table:
		lua.rawgeti(L, refs, lua.Integer(it.a + 1))
	case .Pointer:
		lua.pushlightuserdata(L, rawptr(uintptr(it.bits)))
	}
}
