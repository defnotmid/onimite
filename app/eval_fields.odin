package onimite_app

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"

// A row's members read from its own struct by Odin's runtime type
// information, as onib's (after RAD Debugger's evaluator reading a program's
// types from its debug info). Each field is a member under its name; its
// type gives the value's kind: a number, a boolean, an enum's name (its
// domain its names), a Text_Span read through its table's text (a name type
// of another kind's row, Cue_Name or Track_Name, its domain that kind's
// names), a struct a row of its own. A `m` tag hides (`-`), flattens (`+`)
// or renames a field. A union shows its active variant's fields, a `kind`
// first, its variant's name. (onib's Within / At_Least bounds come with
// B's sliders, range1: no field here is bounded yet.) The rows are
// onimite's own structs, so
// their tags are ours; an engine's or a sibling's types are copied into rows.

// Where a field sits below its row (`row`): field indices from the row's
// struct, a union taking its active variant on the way. `kind`: the
// union's variant, `fixed` when it can't be set (a flattened union's).
Field_Path :: struct {
	row:   Ref,
	at:    [6]u8,
	depth: u8,
	kind:  bool,
	fixed: bool,
}

// A field found by a walk: its name, where it lies in the reader's copy of
// the row, and its type.
Field :: struct {
	name: string,
	ptr:  rawptr,
	id:   typeid,
	path: Field_Path,
}

// How a kind's rows are read by RTTI, as RAD's per-type access hooks: the
// row's type, a copy of a row for one evaluation, the text its spans read,
// and the members it computes rather than holds (`computed`, after its
// fields).
Field_Rows :: struct {
	type:     typeid,
	copy:     proc(r: ^Reader, row: i32) -> rawptr,
	text:     proc(r: ^Reader) -> []u8,
	computed: proc(r: ^Reader, row: Value, out: ^[dynamic]Child),
}

@(private = "file")
tables_text :: proc(r: ^Reader) -> []u8 {return r.tables.text[:]}

@(private = "file")
waves_text :: proc(r: ^Reader) -> []u8 {return r.waves.text[:]}

FIELD_ROWS := #partial [Kind]Field_Rows {
	// A scene's problems are the problems seen in it.
	.Scene = {
		type = Scene_Row,
		copy = proc(r: ^Reader, row: i32) -> rawptr {return new_clone(r.tables.scenes[row], context.temp_allocator)},
		text = tables_text,
		computed = proc(r: ^Reader, row: Value, out: ^[dynamic]Child) {
			append(out, Child{"problems", ".problems", {kind = .Problems, ref = row.ref}})
		},
	},
	.Cue = {
		type = Cue_Row,
		copy = proc(r: ^Reader, row: i32) -> rawptr {return new_clone(r.tables.cues[row], context.temp_allocator)},
		text = tables_text,
	},
	// A problem's scenes are the scenes it was seen in.
	.Problem = {
		type = Problem_Row,
		copy = proc(r: ^Reader, row: i32) -> rawptr {return new_clone(r.tables.problems[row], context.temp_allocator)},
		text = tables_text,
		computed = proc(r: ^Reader, row: Value, out: ^[dynamic]Child) {
			append(out, Child{"scenes", ".scenes", {kind = .Scenes, ref = row.ref}})
		},
	},
	.Media_File = {
		type = Media_File_Row,
		copy = proc(r: ^Reader, row: i32) -> rawptr {return new_clone(r.tables.media[row], context.temp_allocator)},
		text = tables_text,
	},
	.Mark = {
		type = Mark,
		copy = proc(r: ^Reader, row: i32) -> rawptr {return new_clone(r.tables.marks[row], context.temp_allocator)},
		text = tables_text,
	},
	// A track's tracks are the rows under it on the timeline (a group's
	// tracks, a track's parts).
	.Track = {
		type = Track_Row,
		copy = proc(r: ^Reader, row: i32) -> rawptr {return new_clone(r.waves.tracks[row], context.temp_allocator)},
		text = waves_text,
		computed = proc(r: ^Reader, row: Value, out: ^[dynamic]Child) {
			append(out, Child{"tracks", ".tracks", {kind = .Tracks, ref = row.ref}})
		},
	},
}

// A row value's row, copied for this evaluation, and its type.
field_row :: proc(r: ^Reader, row: Ref) -> (rawptr, typeid) {
	rows := FIELD_ROWS[row.kind]
	if rows.copy == nil || row.row < 0 || int(row.row) >= row_count(r, row.kind) do return nil, nil
	return rows.copy(r, row.row), rows.type
}

// How many rows a row kind's table has.
row_count :: proc(r: ^Reader, k: Kind) -> int {
	t := r.tables
	#partial switch k {
	case .Scene:
		return len(t.scenes)
	case .Cue:
		return len(t.cues)
	case .Problem:
		return len(t.problems)
	case .Media_File:
		return len(t.media)
	case .Mark:
		return len(t.marks)
	case .Track:
		return len(r.waves.tracks)
	}
	return 0
}

path_add :: proc(p: Field_Path, i: int) -> Field_Path {
	q := p
	q.at[q.depth] = u8(i)
	q.depth += 1
	return q
}

// The struct a union holds now, at the union's own address.
active :: proc(ptr: rawptr, id: typeid) -> typeid {
	return reflect.union_variant_typeid(any{ptr, id})
}

// Where `path` leads from a row at `base` of type `id`.
field_at :: proc(base: rawptr, id: typeid, path: Field_Path) -> Field {
	f := Field{ptr = base, id = id}
	for i in 0 ..< int(path.depth) {
		if reflect.is_union(type_info_of(f.id)) do f.id = active(f.ptr, f.id)
		s := runtime.type_info_base(type_info_of(f.id)).variant.(runtime.Type_Info_Struct)
		k := int(path.at[i])
		f.ptr = rawptr(uintptr(f.ptr) + s.offsets[k])
		f.id, f.name = s.types[k].id, s.names[k]
		if m := reflect.struct_tag_get(reflect.Struct_Tag(s.tags[k]), "m"); m != "" && m != "+" do f.name = m
	}
	f.path = path
	return f
}

// The members of the struct (or union's variant) at `f`, `m:"+"` fields'
// own in their place, `m:"-"` fields left out.
field_members :: proc(f: Field, out: ^[dynamic]Field) {
	id := reflect.is_union(type_info_of(f.id)) ? active(f.ptr, f.id) : f.id
	s, is_struct := runtime.type_info_base(type_info_of(id)).variant.(runtime.Type_Info_Struct)
	if !is_struct do return
	for k in 0 ..< int(s.field_count) {
		m := reflect.struct_tag_get(reflect.Struct_Tag(s.tags[k]), "m")
		if m == "-" do continue
		g := Field{m != "" && m != "+" ? m : s.names[k], rawptr(uintptr(f.ptr) + s.offsets[k]), s.types[k].id, path_add(f.path, k)}
		if m != "+" {
			append(out, g)
			continue
		}
		// A flattened union shows its variant first, as a `kind` it can't set.
		if reflect.is_union(type_info_of(g.id)) {
			k := g.path
			k.kind, k.fixed = true, true
			append(out, Field{"kind", g.ptr, g.id, k})
		}
		field_members(g, out)
	}
}

// The members of a row value: a union row's `kind` first, then its fields.
value_fields :: proc(r: ^Reader, v: Value, out: ^[dynamic]Field) {
	row := field_owner(v)
	base, id := field_row(r, row)
	if base == nil do return
	f := field_at(base, id, v.field)
	f.path.row = row
	if reflect.is_union(type_info_of(f.id)) {
		k := f.path
		k.kind = true
		append(out, Field{"kind", f.ptr, f.id, k})
	}
	field_members(f, out)
}

// The row a value's fields belong to: a field's own, else the row it is.
field_owner :: proc(v: Value) -> Ref {return v.field.row != {} ? v.field.row : v.ref}

// A row value's members: its fields, then what its table computes.
field_children :: proc(r: ^Reader, v: Value, out: ^[dynamic]Child) {
	fields := make([dynamic]Field, context.temp_allocator)
	value_fields(r, v, &fields)
	reserve(out, len(out) + len(fields))
	for f in fields do append(out, Child{f.name, strings.concatenate({".", f.name}, context.temp_allocator), field_value(r, field_owner(v), f)})
	if v.field.depth == 0 && FIELD_ROWS[v.kind].computed != nil do FIELD_ROWS[v.kind].computed(r, v, out)
}

// Member `name` of a row value, or why it has none: which variants have it.
field_member :: proc(r: ^Reader, base: Value, name: string) -> (Value, string) {
	kids := make([dynamic]Child, context.temp_allocator)
	field_children(r, base, &kids)
	for c in kids {if c.label == name do return c.value, ""}
	return {}, field_missing(r, base, name)
}

// "only a spot has cone": the variants of a union on the way that have `name`.
@(private = "file")
field_missing :: proc(r: ^Reader, base: Value, name: string) -> string {
	missing := fmt.tprintf("a %s has no member %q", value_noun(base), name)
	row, id := field_row(r, field_owner(base))
	if row == nil do return missing
	f := field_at(row, id, base.field)
	u := f.id
	if !reflect.is_union(type_info_of(u)) {
		s, is_struct := runtime.type_info_base(type_info_of(u)).variant.(runtime.Type_Info_Struct)
		if !is_struct do return missing
		for k in 0 ..< int(s.field_count) {if reflect.is_union(s.types[k]) && reflect.struct_tag_get(reflect.Struct_Tag(s.tags[k]), "m") == "+" do u = s.types[k].id}
	}
	if !reflect.is_union(type_info_of(u)) do return missing
	names := make([dynamic]string, context.temp_allocator)
	for variant in runtime.type_info_base(type_info_of(u)).variant.(runtime.Type_Info_Union).variants {
		if s, ok := runtime.type_info_base(variant).variant.(runtime.Type_Info_Struct); ok {
			for k in 0 ..< int(s.field_count) {
				if s.names[k] == name || reflect.struct_tag_get(reflect.Struct_Tag(s.tags[k]), "m") == name do append(&names, variant_name(u, variant.id))
			}
		}
	}
	if len(names) == 0 do return missing
	return fmt.tprintf("only a %s has %s", strings.join(names[:], " or a ", context.temp_allocator), name)
}

// A variant's name: its type's, less its union's and an underscore
// (Light_Spot: spot), lowercase.
variant_name :: proc(u, variant: typeid) -> string {
	short :: proc(id: typeid) -> string {
		name := fmt.tprint(id)
		if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[dot + 1:]
		return name
	}
	name, prefix := short(variant), short(u)
	if strings.has_prefix(name, prefix) && len(name) > len(prefix) && name[len(prefix)] == '_' {name = name[len(prefix) + 1:]} else if i := strings.index_byte(name, '_'); i >= 0 {name = name[i + 1:]}
	return strings.to_lower(name, context.temp_allocator)
}

variant_names :: proc(u: typeid) -> []string {
	variants := runtime.type_info_base(type_info_of(u)).variant.(runtime.Type_Info_Union).variants
	out := make([]string, len(variants), context.temp_allocator)
	for v, i in variants do out[i] = variant_name(u, v.id)
	return out
}

// An enum's names as the evaluator writes them: its values' names in
// lowercase, in the order of its values.
enum_names :: proc(id: typeid) -> []string {
	names := reflect.enum_field_names(id)
	out := make([]string, len(names), context.temp_allocator)
	for n, i in names do out[i] = strings.to_lower(n, context.temp_allocator)
	return out
}

// A number field's value, whatever its integer or float type.
number_at :: proc(ptr: rawptr, id: typeid) -> f64 {
	#partial switch t in runtime.type_info_base(type_info_of(id)).variant {
	case runtime.Type_Info_Integer:
		if t.signed {x, _ := reflect.as_i64(any{ptr, id}); return f64(x)}
		x, _ := reflect.as_u64(any{ptr, id})
		return f64(x)
	}
	x, _ := reflect.as_f64(any{ptr, id})
	return x
}

// The kind of a field of type `id`, from the type alone.
field_kind :: proc(id: typeid) -> Kind {
	switch id {
	case Text_Span, Cue_Name, Track_Name:
		return .Text
	}
	#partial switch t in runtime.type_info_base(type_info_of(id)).variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float:
		return .Number
	case runtime.Type_Info_Boolean:
		return .Boolean
	case runtime.Type_Info_Enum, runtime.Type_Info_String:
		return .Text
	}
	// A struct is a row of its own when a kind reads it.
	for rows, k in FIELD_ROWS {if rows.type == id && id != nil do return k}
	return .Invalid
}

// The value of field `f` of row `owner`.
field_value :: proc(r: ^Reader, owner: Ref, f: Field) -> Value {
	v := Value{ref = owner, field = f.path, kind = field_kind(f.id)}
	if f.path.kind {
		v.kind, v.text, v.domain = .Text, variant_name(f.id, active(f.ptr, f.id)), !f.path.fixed
		return v
	}
	switch f.id {
	case Text_Span:
		v.text = text_of(FIELD_ROWS[owner.kind].text(r), (^Text_Span)(f.ptr)^)
		return v
	case Cue_Name, Track_Name:
		// A name of another kind's row: that kind's names are its domain.
		v.text = text_of(FIELD_ROWS[owner.kind].text(r), (^Text_Span)(f.ptr)^)
		v.domain = true
		return v
	}
	#partial switch t in runtime.type_info_base(type_info_of(f.id)).variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float:
		v.number = number_at(f.ptr, f.id)
		v.type = runtime.typeid_base(f.id)
	case runtime.Type_Info_Boolean:
		v.boolean = (^bool)(f.ptr)^
	case runtime.Type_Info_String:
		v.text = (^string)(f.ptr)^
	case runtime.Type_Info_Enum:
		v.domain = true
		x, _ := reflect.as_i64(any{f.ptr, f.id})
		for value, i in t.values {if i64(value) == x do v.text = enum_names(f.id)[i]}
	}
	return v
}

// What field value `v` may hold, each labelled by its name: a union's
// variants, an enum's names, a name type's kind's names (a scene's cue:
// the cues'; a cue's hit: the tracks').
field_domain :: proc(r: ^Reader, v: Value, out: ^[dynamic]Child) {
	base, id := field_row(r, v.field.row)
	if base == nil do return
	f := field_at(base, id, v.field)
	words: []string
	switch {
	case v.field.kind:
		words = variant_names(f.id)
	case f.id == Cue_Name:
		names := make([dynamic]string, 0, len(r.tables.cues), context.temp_allocator)
		for c in r.tables.cues do append(&names, text_of(r.tables.text[:], c.name))
		words = names[:]
	case f.id == Track_Name:
		names := make([dynamic]string, 0, len(r.waves.tracks), context.temp_allocator)
		for t in r.waves.tracks do if t.kind == .Track do append(&names, text_of(r.waves.text[:], t.name))
		words = names[:]
	case reflect.is_enum(type_info_of(f.id)):
		words = enum_names(f.id)
	}
	for w, i in words do append(out, Child{w, fmt.tprintf("[%d]", i), {kind = .Text, text = w}})
}
