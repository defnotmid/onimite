package onimite_app

import "core:fmt"
import "core:slice"
import "core:strings"
import "../expr"

// Every collection a value unfolds to has RAD Debugger's type expand hooks
// (eval/eval_core.h:482-497), as onib's:
// - `info` counts the elements a filter keeps, matching each element's
//   label with fuzzy_find inside the collection (the one matcher, RAD's),
//   and makes what the other hooks read (RAD's user_data);
// - `range` builds the rows numbered [lo, hi) only, labelled;
// - `id_from_num` and `num_from_id` turn a row's number into its element's
//   identity and back, so an open row keeps to its element as rows reorder,
//   a filter narrows them or the script reloads, as RAD's expansion keys do.
// A row's members are the default collection (RAD's
// e_type_expand_rule__default), identified by their names. Shared code
// reads the table by kind and never names a collection.

// Children of a row (its members) or a collection (its elements),
// labelled; `suffix` appends to the parent's source.
Child :: struct {
	label, suffix: string,
	value:         Value,
}

// A child's identity among its parent's (Row_Id.text: a member's suffix).
Row_Id :: struct {
	tag:  u8,
	id:   u64,
	text: string,
}

Collection_Info :: struct {
	count: int, // the elements the filter keeps; unfiltered, all
	rows:  []i32, // the table rows its elements are, by position (nil: position p is row p)
	of:    Kind, // their kind
	kids:  []Child, // or its elements listed whole (a row's members, a domain's choices)
	shown: []int, // filtered: the positions kept, ascending; nil keeps every position
}

Collection :: struct {
	info:        proc(r: ^Reader, v: Value, filter: string) -> Collection_Info,
	range:       proc(r: ^Reader, v: Value, info: ^Collection_Info, lo, hi: int, out: []Child), // out: the caller's, hi - lo long
	id_from_num: proc(r: ^Reader, v: Value, info: ^Collection_Info, num: int) -> Row_Id,
	num_from_id: proc(r: ^Reader, v: Value, info: ^Collection_Info, id: Row_Id) -> int, // -1 when not shown
}

// A collection of a table's rows: all of them, or a span of an index the
// producers made (a scene's problems, a problem's scenes, a track's
// children), identified by their rows' stable ids.
@(private = "file")
ROWS_COLLECTION :: Collection {
	info        = proc(r: ^Reader, v: Value, filter: string) -> Collection_Info {
		rows, total := table_rows(r, v)
		return collection_filter(r, v, {count = total, rows = rows, of = KINDS[v.kind].of}, filter)
	},
	range       = proc(r: ^Reader, v: Value, info: ^Collection_Info, lo, hi: int, out: []Child) {
		for num in lo ..< hi {
			p := info_place(info, num)
			row := Value{kind = info.of, ref = {info.of, info_row(info, num)}}
			out[num - lo] = {row_label(r, row), element_suffix(r, v, info, row, p), row}
		}
	},
	id_from_num = proc(r: ^Reader, v: Value, info: ^Collection_Info, num: int) -> Row_Id {
		return {ID_TAGS[info.of], row_id(r, {info.of, info_row(info, num)}), ""}
	},
	num_from_id = proc(r: ^Reader, v: Value, info: ^Collection_Info, id: Row_Id) -> int {
		if id.tag != ID_TAGS[info.of] do return -1
		_, total := table_rows(r, v)
		for p in 0 ..< total {
			if row_id(r, {info.of, info.rows != nil ? info.rows[p] : i32(p)}) == id.id do return info_number(info, p)
		}
		return -1
	},
}

COLLECTIONS := #partial [Kind]Collection {
	.Scenes   = ROWS_COLLECTION,
	.Cues     = ROWS_COLLECTION,
	.Problems = ROWS_COLLECTION,
	.Media    = ROWS_COLLECTION,
	.Marks    = ROWS_COLLECTION,
	.Tracks   = ROWS_COLLECTION,
	// A field's allowed values, listed whole.
	.Domain   = {
		info = proc(r: ^Reader, v: Value, filter: string) -> Collection_Info {
			kids := make([dynamic]Child, context.temp_allocator)
			field_domain(r, v, &kids)
			return collection_filter(r, v, {count = len(kids), kids = kids[:]}, filter)
		},
		range = kids_range,
		id_from_num = kids_id_from_num,
		num_from_id = kids_num_from_id,
	},
}

// A row's members: the default collection, listed whole.
MEMBER_COLLECTION :: Collection {
	info        = proc(r: ^Reader, v: Value, filter: string) -> Collection_Info {
		kids := make([dynamic]Child, context.temp_allocator)
		if v.kind in ROW_KINDS do field_children(r, v, &kids)
		return collection_filter(r, v, {count = len(kids), kids = kids[:]}, filter)
	},
	range       = kids_range,
	id_from_num = kids_id_from_num,
	num_from_id = kids_num_from_id,
}

// The collection value `v` unfolds to: its kind's, else its members. The
// lenses (rows, omit) will pick theirs here first, as onib's.
collection :: proc(v: Value) -> Collection {
	c := COLLECTIONS[v.kind]
	if c.info == nil do return MEMBER_COLLECTION
	return c
}

// Rows lo..hi of `v`'s collection: the one place every child is built.
collection_rows :: proc(r: ^Reader, v: Value, info: ^Collection_Info, lo, hi: int, out: []Child) {
	collection(v).range(r, v, info, lo, hi, out)
}

// Keeps the elements whose labels match `filter` (RAD's collections run
// fuzzy_match_find on each element in their info).
collection_filter :: proc(r: ^Reader, v: Value, info: Collection_Info, filter: string) -> Collection_Info {
	if filter == "" do return info
	info := info
	shown := make([dynamic]int, 0, info.count, context.temp_allocator)
	for p in 0 ..< info.count {
		label := info.kids[p].label if info.kids != nil else row_label(r, {kind = info.of, ref = {info.of, info_row(&info, p)}})
		if fuzzy_find(label, filter) do append(&shown, p)
	}
	info.shown, info.count = shown[:], len(shown)
	return info
}

// The places of the rows of collection `v` named `name`, ascending: the
// producers' names index for a whole table, else its span read.
collection_named :: proc(r: ^Reader, v: Value, name: string) -> []int {
	t := r.tables
	out := make([dynamic]int, context.temp_allocator)
	found: []i32
	if v.ref == {} {
		#partial switch v.kind {
		case .Scenes:
			found = names_find(t.scene_names[:], t.text[:], t.scenes[:], name)
		case .Cues:
			found = names_find(t.cue_names[:], t.text[:], t.cues[:], name)
		case .Media:
			found = names_find(t.media_names[:], t.text[:], t.media[:], name)
		}
	}
	if v.kind == .Tracks {
		// a span of the tracks' kids: its names index beside it
		span := v.ref == {} ? r.waves.track_top : r.waves.tracks[v.ref.row].children
		w := r.waves
		for row in names_find(w.track_names[span[0]:][:span[1]], w.text[:], w.tracks[:], name) {
			p, _ := slice.linear_search(w.track_kids[span[0]:][:span[1]], row)
			append(&out, p)
		}
		slice.sort(out[:])
		return out[:]
	}
	if found != nil || v.ref == {} {
		for row in found do append(&out, int(row))
		return out[:]
	}
	// a span of another index (a problem's scenes): read in place
	rows, total := table_rows(r, v)
	for p in 0 ..< total {
		row := Value{kind = KINDS[v.kind].of, ref = {KINDS[v.kind].of, rows != nil ? rows[p] : i32(p)}}
		if row_name(r, row) == name do append(&out, p)
	}
	return out[:]
}

// A collection value's table rows: nil for a whole table (position p is
// row p), else the span of the index it reads; and how many.
@(private = "file")
table_rows :: proc(r: ^Reader, v: Value) -> (rows: []i32, count: int) {
	t := r.tables
	#partial switch v.kind {
	case .Problems:
		if v.ref.kind == .Scene {
			s := t.scenes[v.ref.row].problems
			return t.scene_problems[s[0]:][:s[1]], int(s[1])
		}
		return nil, len(t.problems)
	case .Scenes:
		if v.ref.kind == .Problem {
			s := t.problems[v.ref.row].scenes
			return t.problem_scenes[s[0]:][:s[1]], int(s[1])
		}
		return nil, len(t.scenes)
	case .Cues:
		return nil, len(t.cues)
	case .Media:
		return nil, len(t.media)
	case .Marks:
		return nil, len(t.marks)
	case .Tracks:
		w := r.waves
		span := v.ref.kind == .Track ? w.tracks[v.ref.row].children : w.track_top
		return w.track_kids[span[0]:][:span[1]], int(span[1])
	}
	return nil, 0
}

// How a row is written after its collection's source: `.Race` for a name
// that is an identifier only it has (and no member of the collection's),
// `["Big Finish"]` for another name only it has, else its place `[3]`.
@(private = "file")
element_suffix :: proc(r: ^Reader, v: Value, info: ^Collection_Info, row: Value, place: int) -> string {
	name := row_name(r, row)
	if name != "" && len(collection_named(r, v, name)) == 1 {
		if expr.is_identifier(name) && name != "status" do return strings.concatenate({".", name}, context.temp_allocator)
		return fmt.tprintf("[%s]", expr.quote(name))
	}
	return fmt.tprintf("[%d]", place)
}

// Row `row` of the tracks written as the expression that names it, its
// groups' rows first: `tracks["bus sfx"].tracks.early`.
track_source :: proc(r: ^Reader, row: i32) -> string {
	w := r.waves
	parent := i32(-1)
	for p := w.items[w.tracks[row].item].parent; p >= 0 && parent < 0; p = w.items[p].parent do parent = w.items[p].row
	v := Value{kind = .Tracks}
	source := "tracks"
	if parent >= 0 {
		v.ref = {.Track, parent}
		source = strings.concatenate({track_source(r, parent), ".tracks"}, context.temp_allocator)
	}
	rows, _ := table_rows(r, v)
	place, _ := slice.linear_search(rows, row)
	return strings.concatenate({source, element_suffix(r, v, nil, {kind = .Track, ref = {.Track, row}}, place)}, context.temp_allocator)
}

// A row's stable id: what its producer gives it (a scene its name and how
// many before it share it, a cue or a file its name, a problem its
// finding's key, a mark its number, a track its timeline path's hash).
row_id :: proc(r: ^Reader, ref: Ref) -> u64 {
	t := r.tables
	#partial switch ref.kind {
	case .Scene:
		return t.scenes[ref.row].id
	case .Cue:
		return t.cues[ref.row].id
	case .Problem:
		return t.problems[ref.row].id
	case .Media_File:
		return t.media[ref.row].id
	case .Mark:
		return u64(t.marks[ref.row].n)
	case .Track:
		return r.waves.tracks[ref.row].id
	}
	return 0
}

// A collection of rows is identified by their stable ids, tagged by kind.
ID_TAGS := #partial [Kind]u8 {
	.Scene      = 's',
	.Cue        = 'c',
	.Problem    = 'p',
	.Media_File = 'f',
	.Mark       = 'm',
	.Track      = 't',
}

row_id_text :: proc(id: Row_Id) -> string {
	if id.tag == '.' do return id.text
	return fmt.tprintf("%c%x", id.tag, id.id)
}

row_id_parse :: proc(text: string) -> Row_Id {
	if text == "" do return {}
	if text[0] == '.' || text[0] == '[' do return {'.', 0, text}
	id: u64
	for c in text[1:] {
		d: u64
		switch c {
		case '0' ..= '9':
			d = u64(c - '0')
		case 'a' ..= 'f':
			d = u64(c - 'a' + 10)
		case:
			return {}
		}
		id = id * 16 + d
	}
	return {text[0], id, ""}
}

// The position of row number `num`: the one the filter kept, else itself.
info_place :: proc(info: ^Collection_Info, num: int) -> int {return info.shown != nil ? info.shown[num] : num}

// The row number of position `p`, -1 when the filter dropped it or there is none.
info_number :: proc(info: ^Collection_Info, p: int) -> int {
	if info.shown == nil do return p >= 0 && p < info.count ? p : -1
	num, found := slice.binary_search(info.shown, p)
	return found ? num : -1
}

// The table row of row number `num`.
info_row :: proc(info: ^Collection_Info, num: int) -> i32 {
	p := info_place(info, num)
	return info.rows != nil ? info.rows[p] : i32(p)
}

kids_range :: proc(r: ^Reader, v: Value, info: ^Collection_Info, lo, hi: int, out: []Child) {
	for num in lo ..< hi do out[num - lo] = info.kids[info_place(info, num)]
}

// A listed collection's rows are identified by their suffixes (`.name`, `[3]`).
kids_id_from_num :: proc(r: ^Reader, v: Value, info: ^Collection_Info, num: int) -> Row_Id {return {'.', 0, info.kids[info_place(info, num)].suffix}}

kids_num_from_id :: proc(r: ^Reader, v: Value, info: ^Collection_Info, id: Row_Id) -> int {
	if id.tag != '.' do return -1
	for c, p in info.kids {if c.suffix == id.text do return info_number(info, p)}
	return -1
}
