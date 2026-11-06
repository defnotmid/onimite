package onimite_app

import "core:fmt"
import "core:slice"
import "core:strings"
import "../expr"

// A Watch's rows, one model for every list of values (onib's view_blocks,
// after RAD Debugger's block tree): its expressions' values, unfolded where
// a row is open, the top-level ones filtered by the view's filter. Each row
// is an expression with a typed value at a depth. Every expression (each
// item of a comma list) is a top-level row, or, scoped, its children are
// (a Watch tab on `video:scenes`, the go-to lister's `scenes, cues, ...`).

// One of a Watch's expressions: its source (owned) and its id in its view;
// its rows' keys start with the id, so open rows keep to it as
// expressions move.
Watch_Input :: struct {
	source: string,
	id:     u32,
}

View_Row :: struct {
	input:                int, // the expression it descends from (its place in the view)
	source, label, error: string,
	value:                Value,
	depth:                int,
	root, expanded:       bool, // root: an expression's own row, which edits
	unfolds:              bool, // it has rows to unfold
	// Its identity in the view, under its parent's: its collection's id for
	// it (a row's stable id, a member's name). Open rows keep to it as rows
	// reorder, a filter narrows them or the script reloads, as RAD
	// Debugger's expansion keys do.
	key:                  string,
	// A visualizer's rows, which it fills as one item (RAD's single item,
	// eval_visualization_core.c:505), those of them above the window and
	// those below it (:936); size 0 is a row of one.
	size, skip, chop:     int,
}

// What a value shows in place of its members, across the rows it spans
// (RAD's view rules: a value's type picks one, and it unfolds into it). A
// failed file has nothing to show, and unfolds into its members.
Visualizer :: enum u8 {
	Image,
	Audio,
}

VISUALIZER_ROWS := [Visualizer]int {
	.Image = 8, // RAD's bitmap, raddbg_views.c:4880
	.Audio = 4,
}

// The view that presents it, a row's and a tab's the same (RAD's view of a
// value, rd_view_from_eval, raddbg_core.c:1481).
VISUALIZER_VIEWS := [Visualizer]View_Kind {
	.Image = .Image,
	.Audio = .Audio,
}

visualizer_of :: proc(r: ^Reader, v: Value) -> (lens: Visualizer, ok: bool) {
	if v.kind != .Media_File do return
	m := r.tables.media[v.ref.row]
	if m.failed do return
	#partial switch m.kind {
	case .Image:
		return .Image, true
	case .Audio:
		return .Audio, true
	}
	return
}

// A visualizer's row key, under the row it unfolds.
visualizer_key :: proc(row_key: string) -> string {return strings.concatenate({row_key, "/v"}, context.temp_allocator)}

// What a Watch shows: its expressions, whether scoped, its filter and its
// open rows' keys.
Watch_Rows_Source :: struct {
	inputs:   []Watch_Input,
	scoped:   bool,
	filter:   string,
	expanded: []string,
}

item_key :: proc(input: Watch_Input, k: int) -> string {return k == 0 ? fmt.tprintf("i%d", input.id) : fmt.tprintf("i%d,%d", input.id, k)}

// An expression's items: a comma list's, in order, else the expression
// alone, each its text and its root in `nodes`; a view shows each item's
// rows as consecutive top-level blocks, as RAD Debugger's block tree
// follows an expression's chain (eval_visualization_core.c:619-633).
Item :: struct {
	source: string,
	at:     int,
}

source_items :: proc(source: string, nodes: ^[dynamic]expr.Node, out: ^[dynamic]Item) -> (error: string) {
	root: int
	if root, error = expr.parse(source, nodes); error != "" do return
	if nodes[root].op != .List {append(out, Item{source, root}); return}
	for link := root; link >= 0; link = nodes[link].b do append(out, Item{nodes[link].text, nodes[link].a})
	return
}

// Whether a value unfolds: a row to its members, a collection to its rows.
expandable :: proc(v: Value) -> bool {return v.kind in ROW_KINDS || v.kind in SEQUENCE_KINDS}

// A view's rows as RAD Debugger lays them out (ev_block_tree_from_eval,
// eval_visualization_core.c:396): first its blocks (each open row's
// children, a collection counted by its info hook, and which of them are
// open, found from their keys by num_from_id, each a block of its own),
// then spans of row numbers over them in order. A consumer then asks the
// spans: the total, a window of rows (only these are built, by the range
// hook), or a key's row number. The filter narrows only the top-level rows
// (:489): the expressions' own rows, or a scoped one's children; rows below
// an open row show unfiltered, and nothing opens to search.
View_Block :: struct {
	row:   View_Row, // the open row; a scoped expression's own row is not shown
	info:  Collection_Info, // the children its filter keeps, and what its range reads
	opens: []Block_Open, // by row number, ascending
	rows:  int, // a visualizer's: one item over these rows, its info's count; 0 a collection's
}

// (the timeline's rows below the scenes share these: Row_Block)
Block_Open :: struct {
	at, block: int, // a child's row number among the block's, and its block
}

// Rows [lo, hi) of block `block`'s children, or with block -1 of `tops`;
// with `opens`, its last row's block follows.
Row_Span :: struct {
	block, lo, hi: int,
	opens:         bool,
}

View_Blocks :: struct {
	r:        Reader,
	expanded: []string,
	tops:     [dynamic]View_Row, // the expressions' own rows, those the filter keeps
	blocks:   [dynamic]View_Block,
	spans:    [dynamic]Row_Span,
	total:    int,
}

view_blocks :: proc(r: Reader, src: Watch_Rows_Source) -> View_Blocks {
	b := View_Blocks{r = r, expanded = src.expanded}
	b.tops = make([dynamic]View_Row, context.temp_allocator)
	b.blocks = make([dynamic]View_Block, context.temp_allocator)
	b.spans = make([dynamic]Row_Span, context.temp_allocator)
	nodes := make([dynamic]expr.Node, context.temp_allocator)
	items := make([dynamic]Item, context.temp_allocator)
	for input, i in src.inputs {
		clear(&items)
		parse_error := source_items(input.source, &nodes, &items)
		if parse_error != "" do append(&items, Item{input.source, -1})
		for item, k in items {
			root, error := Value{}, parse_error
			if error == "" do root, error = eval(&b.r, nodes[:], item.at)
			top := View_Row{input = i, source = item.source, label = item.source, error = error, value = root, root = true, unfolds = error == "" && expandable(root), key = item_key(input, k)}
			// Scoped, its children are the top-level rows: the filter narrows
			// them, and the item's own row is not shown.
			if error == "" && src.scoped {
				top.label, top.depth, top.root, top.expanded = "", -1, false, true
				spans_of(&b, block_build(&b, top, src.filter))
				continue
			}
			// Else its own row is top-level, kept when its label matches.
			if src.filter != "" && !fuzzy_find(top.label, src.filter) do continue
			top.expanded = top.unfolds && slice.contains(src.expanded, top.key)
			append(&b.tops, top)
			append(&b.spans, Row_Span{-1, len(b.tops) - 1, len(b.tops), top.expanded})
			if top.expanded do spans_of(&b, block_build(&b, top, ""))
		}
	}
	for s in b.spans do b.total += s.hi - s.lo
	return b
}

// The block of open row `row`, its children kept by `filter`.
@(private = "file")
block_build :: proc(b: ^View_Blocks, row: View_Row, filter: string) -> (block: int) {
	block = len(b.blocks)
	append(&b.blocks, View_Block{row = row})
	if row.depth >= 32 || row.error != "" do return
	if lens, ok := visualizer_of(&b.r, row.value); ok {
		k := &b.blocks[block]
		k.rows = VISUALIZER_ROWS[lens]
		k.info.count = k.rows
		return
	}
	c := collection(row.value)
	info := c.info(&b.r, row.value, filter)
	opens := make([dynamic]Block_Open, context.temp_allocator)
	// The open ones, found from their keys; each child built alone.
	prefix := fmt.tprintf("%s/", row.key)
	for e in b.expanded {
		if !below(e, prefix) do continue
		num := c.num_from_id(&b.r, row.value, &info, row_id_parse(e[len(prefix):]))
		if num < 0 do continue
		one: [1]Child
		collection_rows(&b.r, row.value, &info, num, num + 1, one[:])
		child := child_row(b, row, &info, one[0], num)
		if child.unfolds do append(&opens, Block_Open{num, block_build(b, child, "")})
	}
	slice.sort_by(opens[:], proc(x, y: Block_Open) -> bool {return x.at < y.at})
	k := &b.blocks[block]
	k.info, k.opens = info, opens[:]
	return
}

// A block's spans, its open children's between: a span ends at each open row.
@(private = "file")
spans_of :: proc(b: ^View_Blocks, block: int) {
	from := 0
	for o in b.blocks[block].opens {
		append(&b.spans, Row_Span{block, from, o.at + 1, true})
		spans_of(b, o.block)
		from = o.at + 1
	}
	if count := b.blocks[block].info.count; from < count do append(&b.spans, Row_Span{block, from, count, false})
}

@(private = "file")
below :: proc(key, prefix: string) -> bool {return strings.has_prefix(key, prefix) && strings.index_byte(key[len(prefix):], '/') < 0}

// The rows from `first`, at most `limit`: only these are built.
blocks_window :: proc(b: ^View_Blocks, first, limit: int, out: ^[dynamic]View_Row) {
	end := limit > max(int) - first ? max(int) : first + limit
	at := 0
	kids := make([]Child, clamp(b.total - first, 0, limit), context.temp_allocator)
	for s in b.spans {
		n := s.hi - s.lo
		lo, hi := s.lo + clamp(first - at, 0, n), s.lo + clamp(end - at, 0, n)
		at += n
		if s.block < 0 {
			for i in lo ..< hi do append(out, b.tops[i])
			continue
		}
		if lo == hi do continue
		k := &b.blocks[s.block]
		if k.rows > 0 {
			append(out, View_Row{input = k.row.input, source = k.row.source, value = k.row.value, depth = k.row.depth + 1, key = visualizer_key(k.row.key), size = k.rows, skip = lo, chop = k.rows - hi})
			continue
		}
		collection_rows(&b.r, k.row.value, &k.info, lo, hi, kids[:hi - lo])
		for kid, j in kids[:hi - lo] {
			row := child_row(b, k.row, &k.info, kid, lo + j)
			row.expanded = s.opens && lo + j == s.hi - 1
			append(out, row)
		}
	}
}

// The row number of the row keyed `key`, -1 when it is not shown.
blocks_index :: proc(b: ^View_Blocks, key: string) -> int {
	at := 0
	for s in b.spans {
		num := -1
		if s.block < 0 {
			for i in s.lo ..< s.hi {if b.tops[i].key == key do num = i}
		} else if k := &b.blocks[s.block]; k.rows > 0 {
			if key == visualizer_key(k.row.key) do num = 0
		} else if below(key, fmt.tprintf("%s/", k.row.key)) {
			num = collection(k.row.value).num_from_id(&b.r, k.row.value, &k.info, row_id_parse(key[len(k.row.key) + 1:]))
		}
		if num >= s.lo && num < s.hi do return at + num - s.lo
		at += s.hi - s.lo
	}
	return -1
}

// Rows and the items a cursor goes over (RAD's row blocks): a visualizer's
// rows are one item, every other row is one. What lies past the spans (an
// expression Watch's last row) counts a row an item.
blocks_item_from_row :: proc(b: ^View_Blocks, row: int) -> int {
	at, item := 0, 0
	for s in b.spans {
		n := s.hi - s.lo
		single := s.block >= 0 && b.blocks[s.block].rows > 0
		if row < at + n do return item + (single ? 0 : row - at)
		at += n
		item += single ? 1 : n
	}
	return item + row - at
}

blocks_row_from_item :: proc(b: ^View_Blocks, item: int) -> int {
	at, first := 0, 0
	for s in b.spans {
		n := s.hi - s.lo
		single := s.block >= 0 && b.blocks[s.block].rows > 0
		items := single ? 1 : n
		if item < first + items do return at + (single ? 0 : item - first)
		at += n
		first += items
	}
	return at + item - first
}

// Child row `num` of open row `row`, keyed by its collection's id for it.
@(private = "file")
child_row :: proc(b: ^View_Blocks, row: View_Row, info: ^Collection_Info, c: Child, num: int) -> View_Row {
	id := collection(row.value).id_from_num(&b.r, row.value, info, num)
	key := strings.concatenate({row.key, "/", row_id_text(id)}, context.temp_allocator)
	return {input = row.input, source = strings.concatenate({row.source, c.suffix}, context.temp_allocator), label = c.label, value = c.value, depth = row.depth + 1, unfolds = expandable(c.value), key = key}
}
