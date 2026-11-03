package onimite_app

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import "../expr"

// The evaluator, after onib's (itself after RAD Debugger's): an expression
// (expr/) walked over the video's tables (video_tables.odin, and the
// timeline's tracks) into a Value. A value's kind decides how it reads,
// whether it unfolds and what its children are; a row's members are its
// type's fields read by RTTI (eval_fields.odin), a collection's elements its
// rows (eval_collections.odin). The Watch's rows and the lister's are built
// from values (eval_rows.odin); C8b's `onimite show` reads the same ones.

// What a value is.
Kind :: enum u8 {
	Invalid,
	Number,
	Boolean,
	Text,
	Scene,
	Scenes,
	Cue,
	Cues,
	Problem,
	Problems,
	Media_File,
	Media, // the media files
	Mark,
	Marks,
	Track, // a group, a track or a part, as the timeline shows it
	Tracks,
	Domain, // a field's allowed values (`x.domain`): the field's value, its kind changed
}

// Rows whose members are their struct's fields (eval_fields.odin), and the
// collections their elements are.
ROW_KINDS :: bit_set[Kind]{.Scene, .Cue, .Problem, .Media_File, .Mark, .Track}
SEQUENCE_KINDS :: bit_set[Kind]{.Scenes, .Cues, .Problems, .Media, .Marks, .Tracks, .Domain}

// What value.set would write. The preview never writes the script's data
// (humans point, agents edit): every value reads only, until the views'
// and the window's settings (B).
Write :: enum u8 {
	None,
}

// A row by its table and its place there: a value names its rows this way,
// never by a pointer into a table.
Ref :: struct {
	kind: Kind,
	row:  i32,
}

// A value for one evaluation, in the frame's temporary memory with its text:
// no pointers into the tables. Copied by value, so the small fields share
// the first word (onib's: kind, a dimension, a boolean, untyped, a format
// lens's verb and digits), and it stays under 256 bytes, past which a copy
// is no longer inlined.
Value :: struct {
	kind:      Kind,
	dimension: [3]i8, // reserved: onib's units (C8 has none)
	boolean:   bool,
	untyped:   bool, // a literal: it converts to the type it meets, as Odin's constants do
	verb:      u8, // reserved: a format lens's fmt verb
	digits:    u8, // reserved: the digits lens
	number:    f64,
	type:      typeid, // a Number's Odin base type: its field's, or a literal's default
	text:      string,
	// The row it is; a collection's: the row whose collection it is ({}: the
	// whole table).
	ref:       Ref,
	write:     Write,
	domain:    bool, // a field whose type gives its allowed values (field_domain)
	field:     Field_Path, // a field's place below its row
}
#assert(size_of(Value) <= 248)

// The name spaces a name resolves in, tried in this order; a qualifier
// (`video:scenes`) limits a name to one, after RAD Debugger's resolution
// paths and qualifiers (eval/eval_ir.c:1726-1752). `$` and `member:` (a
// lens argument's parent's members) come with the lenses.
Qualifier :: enum u8 {
	Member, // a member of the parent (Reader.parent)
	Video, // the video's tables
	Query, // the preview's own state: views, the window (B)
}

// The qualifiers a name may carry.
QUALIFIER_NAMES :: bit_set[Qualifier]{.Video, .Query}

// The roots every expression starts from, as the evaluator writes enums.
Root :: enum u8 {
	Scenes,
	Cues,
	Problems,
	Media,
	Marks,
	Tracks,
}

ROOT_SPACE := [Root]Qualifier {
	.Scenes   = .Video,
	.Cues     = .Video,
	.Problems = .Video,
	.Media    = .Video,
	.Marks    = .Video,
	.Tracks   = .Video,
}

ROOT_KINDS := [Root]Kind {
	.Scenes   = .Scenes,
	.Cues     = .Cues,
	.Problems = .Problems,
	.Media    = .Media,
	.Marks    = .Marks,
	.Tracks   = .Tracks,
}

// What a kind is called and how a view words it: its title ("Scenes"), its
// noun ("Scene"), what an empty one says, and its rows' kind or its
// collection's.
Kind_Descriptor :: struct {
	title: string,
	noun:  string,
	empty: string,
	of:    Kind, // a collection's rows; a row's collection
}

KINDS := #partial [Kind]Kind_Descriptor {
	.Scene      = {"Scene", "scene", "", .Scenes},
	.Scenes     = {"Scenes", "scenes", "No scenes.", .Scene},
	.Cue        = {"Cue", "cue", "", .Cues},
	.Cues       = {"Cues", "cues", "No cues.", .Cue},
	.Problem    = {"Problem", "problem", "", .Problems},
	.Problems   = {"Problems", "problems", "No problems at load or in the frames shown since.", .Problem},
	.Media_File = {"Media file", "media file", "", .Media},
	.Media      = {"Media", "media", "No media loaded.", .Media_File},
	.Mark       = {"Mark", "mark", "", .Marks},
	.Marks      = {"Marks", "marks", "No marks: [ and ] mark a range, P a moment; the agent reads them.", .Mark},
	.Track      = {"Track", "track", "", .Tracks},
	.Tracks     = {"Tracks", "tracks", "No tracks.", .Track},
	.Domain     = {"Choices", "choices", "No choices.", .Invalid},
}

// The tables an evaluation reads: the video's, and the timeline's (its
// tracks). `parent` is `$` while a lens's arguments evaluate (RAD's parent
// key), nil otherwise; nothing sets it until the lenses come.
Reader :: struct {
	tables: ^Video_Tables,
	waves:  ^Wave_Table,
	parent: ^Value,
}

// Evaluate one expression; a comma list has no single value. Node scratch is
// the temp allocator: values are frame-lived.
evaluate :: proc(r: ^Reader, source: string) -> (Value, string) {
	nodes := make([dynamic]expr.Node, context.temp_allocator)
	root, error := expr.parse(source, &nodes)
	if error != "" do return {}, error
	return eval(r, nodes[:], root)
}

eval :: proc(r: ^Reader, nodes: []expr.Node, at: int) -> (v: Value, error: string) {
	n := nodes[at]
	switch n.op {
	case .Number:
		return {kind = .Number, number = n.number, type = n.integer ? typeid_of(int) : typeid_of(f64), untyped = true}, ""
	case .Text:
		return {kind = .Text, text = n.text}, ""
	case .Name:
		return name_value(r, n.qualifier, n.text)
	case .Member:
		base, base_error := eval(r, nodes, n.a)
		if base_error != "" do return {}, base_error
		return member(r, base, n.text)
	case .Index:
		base, base_error := eval(r, nodes, n.a)
		if base_error != "" do return {}, base_error
		i, i_error := eval(r, nodes, n.b)
		if i_error != "" do return {}, i_error
		// A text index is a row's name: `scenes["two words"]`.
		if i.kind == .Text do return named(r, base, i.text)
		if i.kind != .Number || i.number != math.floor(i.number) do return {}, "an index is a whole number, or a row's name in quotes"
		return element(r, base, int(i.number))
	case .Call:
		callee := nodes[n.a]
		return {}, fmt.tprintf("unknown call %q", callee.text)
	case .List:
		return {}, "a list has no single value"
	}
	return {}, "unknown expression"
}

// What `name` is in name space `space`, if anything.
space_value :: proc(r: ^Reader, space: Qualifier, name: string) -> (Value, bool) {
	if space == .Member {
		if r.parent == nil do return {}, false
		v, error := member(r, r.parent^, name)
		return v, error == ""
	}
	for root_name, k in enum_names(Root) {if root_name == name && ROOT_SPACE[Root(k)] == space do return {kind = ROOT_KINDS[Root(k)]}, true}
	return {}, false
}

// The name spaces a qualifier limits a name to: every one without one. An
// unknown qualifier is an error, as onib's (RAD ignores one, as its
// qualifiers also name modules).
qualifier_spaces :: proc(qualifier: string) -> (bit_set[Qualifier], string) {
	if qualifier == "" do return ~bit_set[Qualifier]{}, ""
	names := make([dynamic]string, context.temp_allocator)
	for space_name, k in enum_names(Qualifier) {
		if Qualifier(k) not_in QUALIFIER_NAMES do continue
		if space_name == qualifier do return {Qualifier(k)}, ""
		append(&names, space_name)
	}
	return {}, fmt.tprintf("unknown space %s (%s)", qualifier, strings.join(names[:], ", ", context.temp_allocator))
}

// A name: in the name space its qualifier names, else the first that has it.
name_value :: proc(r: ^Reader, qualifier, name: string) -> (Value, string) {
	spaces, error := qualifier_spaces(qualifier)
	if error != "" do return {}, error
	for space in spaces {if v, ok := space_value(r, space, name); ok do return v, ""}
	if qualifier != "" do return {}, fmt.tprintf("no %s name %q", qualifier, name)
	return {}, fmt.tprintf("unknown name %q; the roots are %s", name, strings.join(enum_names(Root), ", ", context.temp_allocator))
}

// Member `name` of `base`: a domain's, a row's fields and what its table
// computes, a collection's own members (its `status`), else a row of the
// collection by its name (`scenes.Race`).
member :: proc(r: ^Reader, base: Value, name: string) -> (Value, string) {
	switch {
	case name == "domain" && base.domain:
		// What the field may hold, as RAD's schema gives a setting its list.
		v := base
		v.kind = .Domain
		return v, ""
	case base.kind in ROW_KINDS:
		return field_member(r, base, name)
	case base.kind in SEQUENCE_KINDS && base.kind != .Domain:
		if name == "status" do return collection_status(r, base), ""
		return named(r, base, name)
	}
	return {}, fmt.tprintf("a %s has no member %q", value_noun(base), name)
}

// What a value is called in a message: its kind's noun, or its kind.
value_noun :: proc(v: Value) -> string {
	if d := KINDS[v.kind]; d.noun != "" do return d.noun
	return enum_names(Kind)[v.kind]
}

// The worst status of a collection's rows: the producer's for a whole
// table, else its rows' (a scene's problems, a track's children).
collection_status :: proc(r: ^Reader, v: Value) -> Value {
	worst := Status.Ok
	if v.ref == {} {
		worst = r.tables.worst[v.kind]
	} else {
		info := collection(v).info(r, v, "")
		kids := make([]Child, info.count, context.temp_allocator)
		collection_rows(r, v, &info, 0, info.count, kids)
		for kid in kids do worst = max(worst, row_status(r, kid.value))
	}
	return {kind = .Text, text = enum_names(Status)[worst], domain = true}
}

// A row's status, as the Watch shows it (a mark: info; a track: ok).
row_status :: proc(r: ^Reader, v: Value) -> Status {
	t := r.tables
	#partial switch v.kind {
	case .Scene:
		return t.scenes[v.ref.row].status
	case .Cue:
		return t.cues[v.ref.row].status
	case .Problem:
		return t.problems[v.ref.row].status
	case .Media_File:
		return t.media[v.ref.row].status
	case .Mark:
		return .Info
	}
	return .Ok
}

// The frame a row is at, by its kind (what a click on it goes to, and a
// go-to's register takes from it): a scene's `start`, a cue's `frame`, a
// problem's or a media file's `first`, a mark's `at`; -1 none.
row_frame :: proc(r: ^Reader, v: Value) -> int {
	t := r.tables
	#partial switch v.kind {
	case .Scene:
		return t.scenes[v.ref.row].start
	case .Cue:
		return t.cues[v.ref.row].frame
	case .Problem:
		return t.problems[v.ref.row].first
	case .Media_File:
		return t.media[v.ref.row].first
	case .Mark:
		return t.marks[v.ref.row].at
	}
	return -1
}

// The i-th element of a collection.
element :: proc(r: ^Reader, base: Value, i: int) -> (Value, string) {
	if base.kind not_in SEQUENCE_KINDS do return {}, fmt.tprintf("a %s is not a collection", value_noun(base))
	info := collection(base).info(r, base, "")
	if i < 0 || i >= info.count do return {}, fmt.tprintf("%s[%d] is out of range: %d %s", KINDS[base.kind].noun, i, info.count, KINDS[base.kind].noun)
	one: [1]Child
	collection_rows(r, base, &info, i, i + 1, one[:])
	return one[0].value, ""
}

// The row of a collection named `name`: none is an error, and so are two,
// naming each one's place ("2 scenes named Race: scenes[3], scenes[7]").
named :: proc(r: ^Reader, base: Value, name: string) -> (Value, string) {
	if base.kind not_in SEQUENCE_KINDS || base.kind == .Domain do return {}, fmt.tprintf("a %s has no rows by name", value_noun(base))
	places := collection_named(r, base, name)
	noun := KINDS[base.kind].noun
	switch len(places) {
	case 0:
		return {}, fmt.tprintf("no %s named %q", KINDS[KINDS[base.kind].of].noun, name)
	case 1:
		return element(r, base, places[0])
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d %s named %s:", len(places), noun, name)
	for p, i in places do fmt.sbprintf(&b, "%s %s[%d]", i > 0 ? "," : "", noun, p)
	return {}, strings.to_string(b)
}

// A row's label among its collection's: its name, a problem its message, a
// mark its number.
row_label :: proc(r: ^Reader, v: Value) -> string {
	t := r.tables
	#partial switch v.kind {
	case .Scene:
		return text_of(t.text[:], t.scenes[v.ref.row].name)
	case .Cue:
		return text_of(t.text[:], t.cues[v.ref.row].name)
	case .Problem:
		return text_of(t.text[:], t.problems[v.ref.row].message)
	case .Media_File:
		return text_of(t.text[:], t.media[v.ref.row].name)
	case .Mark:
		label, _ := mark_watch(t.marks[v.ref.row], t.fps)
		return label
	case .Track:
		return text_of(r.waves.text[:], r.waves.tracks[v.ref.row].name)
	}
	return ""
}

// A row's name, for lookups by name ("" for rows without one: a problem, a mark).
row_name :: proc(r: ^Reader, v: Value) -> string {
	#partial switch v.kind {
	case .Scene, .Cue, .Media_File, .Track:
		return row_label(r, v)
	}
	return ""
}

// A float to `places` places (3 when 0), its trailing zeros dropped.
format_number :: proc(x: f64, places: u8 = 0) -> string {
	s := fmt.tprintf("%.*f", places == 0 ? 3 : int(places), x)
	s = strings.trim_right(s, "0")
	s = strings.trim_right(s, ".")
	return s == "-0" ? "0" : s
}

// The display rule: one string per kind, a row worded as the Watch words
// it (items.odin's wording, from the row's fields).
value_text :: proc(r: ^Reader, v: Value) -> string {
	t := r.tables
	count :: proc(n: int, one, many: string) -> string {return fmt.tprintf("%d %s", n, n == 1 ? one : many)}
	switch v.kind {
	case .Number:
		if v.type != nil && reflect.is_integer(type_info_of(v.type)) do return fmt.tprintf("%d", i64(v.number))
		return format_number(v.number)
	case .Boolean:
		return v.boolean ? "true" : "false"
	case .Text:
		return v.text
	case .Scene:
		s := t.scenes[v.ref.row]
		return scene_row_text(text_of(t.text[:], s.name), s.start, s.end, text_of(t.text[:], Text_Span(s.cue)), text_of(t.text[:], s.source), int(s.problems[1]), t.fps)
	case .Cue:
		c := t.cues[v.ref.row]
		return cue_row_text(c.seconds, c.frame, text_of(t.text[:], c.source), text_of(t.text[:], Text_Span(c.hit)), text_of(t.text[:], c.sync))
	case .Problem:
		p := t.problems[v.ref.row]
		if p.reload do return v.ref.row == 0 ? "the script failed to load; the last good version plays" : ""
		scenes := make([]string, p.scenes[1], context.temp_allocator)
		for s, i in t.problem_scenes[p.scenes[0]:][:p.scenes[1]] do scenes[i] = text_of(t.text[:], t.scenes[s].name) if int(s) < len(t.scenes) else ""
		return problem_row_text(p.severity, p.first, p.last, p.frames, scenes, text_of(t.text[:], p.source), t.fps)
	case .Media_File:
		m := t.media[v.ref.row]
		_, detail := media_watch({kind = m.kind, name = text_of(t.text[:], m.name), detail = text_of(t.text[:], m.detail), failed = m.failed}, m.first, t.fps)
		return detail
	case .Mark:
		_, detail := mark_watch(t.marks[v.ref.row], t.fps)
		return detail
	case .Track:
		w := r.waves
		return text_of(w.text[:], w.items[w.tracks[v.ref.row].item].summary)
	case .Scenes, .Cues, .Problems, .Media, .Marks, .Tracks, .Domain:
		n := collection(v).info(r, v, "").count
		if v.kind == .Media do return count(n, "file", "files")
		return count(n, KINDS[KINDS[v.kind].of].noun, KINDS[v.kind].noun) if v.kind != .Domain else count(n, "choice", "choices")
	case .Invalid:
	}
	return ""
}
