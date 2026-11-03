// The expressions a Watch row and `onimite show` read, after onib's
// expression language (itself after RAD Debugger's): names with a
// qualifier (`video:scenes`), members (`scenes.Race`), indices by place
// (`scenes[3]`) or by name (`scenes["Big Finish"]`), calls (kept for
// lenses) and comma lists. Literals are numbers and quoted text only: no
// units and no arithmetic (time specs keep their own parser). Parsing is
// pure; evaluating against the video's tables lives in the app.
package expr

import "core:strconv"
import "core:strings"

Op :: enum u8 {
	Number,
	Text,
	Name, // a root, or `qualifier:name`
	Member, // a.text
	Index, // a[b]
	Call, // a(b, c): `a` the callee, `b` the first link of its arguments (List links, as a comma list's; -1 none)
	List, // a, b, c: one link per item, `a` the item, `b` the next link (-1 last), text the item's source
}

// Children index the same flat node array; -1 is absent.
Node :: struct {
	op:        Op,
	a, b:      int,
	number:    f64,
	integer:   bool, // a Number spelled without a point: Odin's untyped integer
	text:      string, // borrows the source (escaped text: temp memory)
	qualifier: string, // a Name's (`video:scenes`), borrowing the source
	at:        int, // byte offset, for diagnostics
}

Parser :: struct {
	source: string,
	pos:    int,
	nodes:  ^[dynamic]Node,
	error:  string,
}

// Parse into `nodes`, which the caller owns and may reuse; returns the root index.
parse :: proc(source: string, nodes: ^[dynamic]Node) -> (root: int, error: string) {
	clear(nodes)
	p := Parser{source, 0, nodes, ""}
	root = list(&p)
	space(&p)
	if p.error == "" && p.pos < len(p.source) do fail(&p, "unexpected text")
	return root, p.error
}

@(private)
fail :: proc(p: ^Parser, message: string) {
	if p.error == "" do p.error = message
}

@(private)
space :: proc(p: ^Parser) {for p.pos < len(p.source) && strings.is_space(rune(p.source[p.pos])) do p.pos += 1}

@(private)
peek :: proc(p: ^Parser) -> u8 {space(p); return p.pos < len(p.source) ? p.source[p.pos] : 0}

@(private)
accept :: proc(p: ^Parser, c: u8) -> bool {
	if peek(p) != c do return false
	p.pos += 1
	return true
}

@(private)
node :: proc(p: ^Parser, n: Node) -> int {
	m := n
	m.at = p.pos
	append(p.nodes, m)
	return len(p.nodes) - 1
}

// `a, b, c` at the lowest precedence: a chain of links, one per item, as
// RAD Debugger parses a chain of expressions (eval/eval_parse.c:678-724). One
// item alone is no list.
@(private)
list :: proc(p: ^Parser) -> int {
	space(p)
	start := p.pos
	item := postfix(p)
	if p.error != "" || peek(p) != ',' do return item
	first, last := -1, -1
	for {
		link := node(p, {op = .List, a = item, b = -1, text = strings.trim_space(p.source[start:p.pos])})
		if last < 0 {first = link} else {p.nodes[last].b = link}
		last = link
		if !accept(p, ',') do break
		space(p)
		start = p.pos
		item = postfix(p)
		if p.error != "" do break
	}
	return first
}

// A primary and what follows it: members, indices and calls.
@(private)
postfix :: proc(p: ^Parser) -> int {
	a := primary(p)
	for p.error == "" {
		switch {
		case accept(p, '.'):
			name := identifier(p)
			if name == "" {fail(p, "expected a member name"); return a}
			a = node(p, {op = .Member, a = a, b = -1, text = name})
		case accept(p, '['):
			i := postfix(p)
			if !accept(p, ']') {fail(p, "expected ]"); return a}
			a = node(p, {op = .Index, a = a, b = i})
		case accept(p, '('):
			a = node(p, {op = .Call, a = a, b = arguments(p)})
		case:
			return a
		}
	}
	return a
}

// A call's arguments through its `)`: List links, one per argument.
@(private)
arguments :: proc(p: ^Parser) -> int {
	if accept(p, ')') do return -1
	first, last := -1, -1
	for p.error == "" {
		space(p)
		start := p.pos
		item := postfix(p)
		link := node(p, {op = .List, a = item, b = -1, text = strings.trim_space(p.source[start:p.pos])})
		if last < 0 {first = link} else {p.nodes[last].b = link}
		last = link
		if accept(p, ')') do break
		if !accept(p, ',') do fail(p, "expected , or )")
	}
	return first
}

ident_char :: proc(c: u8) -> bool {return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'}

// Whether `name` can be written as a member (`scenes.Race`): an identifier
// not starting with a digit; any other name is an index (`scenes["two words"]`).
is_identifier :: proc(name: string) -> bool {
	if name == "" || name[0] >= '0' && name[0] <= '9' do return false
	for i in 0 ..< len(name) {if !ident_char(name[i]) do return false}
	return true
}

@(private)
identifier :: proc(p: ^Parser) -> string {
	space(p)
	start := p.pos
	for p.pos < len(p.source) && ident_char(p.source[p.pos]) do p.pos += 1
	if start < p.pos && p.source[start] >= '0' && p.source[start] <= '9' {p.pos = start; return ""}
	return p.source[start:p.pos]
}

@(private)
primary :: proc(p: ^Parser) -> int {
	c := peek(p)
	switch {
	case c == '(':
		p.pos += 1
		a := postfix(p)
		if !accept(p, ')') do fail(p, "expected )")
		return a
	case c == '"':
		// Escapes \n, \" and \\; text without them borrows the source.
		p.pos += 1
		start := p.pos
		escaped := false
		for p.pos < len(p.source) && p.source[p.pos] != '"' {
			if p.source[p.pos] == '\\' {escaped = true; p.pos += 1}
			p.pos += 1
		}
		if p.pos >= len(p.source) {fail(p, "unterminated text"); return -1}
		raw := p.source[start:p.pos]
		p.pos += 1
		if !escaped do return node(p, {op = .Text, a = -1, b = -1, text = raw})
		b := strings.builder_make(context.temp_allocator)
		for i := 0; i < len(raw); i += 1 {
			if raw[i] != '\\' || i + 1 == len(raw) {strings.write_byte(&b, raw[i]); continue}
			i += 1
			strings.write_byte(&b, raw[i] == 'n' ? '\n' : raw[i])
		}
		return node(p, {op = .Text, a = -1, b = -1, text = strings.to_string(b)})
	case c >= '0' && c <= '9':
		return number(p)
	case ident_char(c):
		name := identifier(p)
		// A qualifier limits the name after it to one name space, as RAD
		// Debugger's do (eval/eval_parse.c:854-899).
		if accept(p, ':') {
			qualified := identifier(p)
			if qualified == "" {fail(p, "expected a name after the qualifier"); return -1}
			return node(p, {op = .Name, a = -1, b = -1, text = qualified, qualifier = name})
		}
		return node(p, {op = .Name, a = -1, b = -1, text = name})
	}
	fail(p, "expected a value")
	return -1
}

@(private)
number :: proc(p: ^Parser) -> int {
	start := p.pos
	for p.pos < len(p.source) && (p.source[p.pos] >= '0' && p.source[p.pos] <= '9' || p.source[p.pos] == '.') do p.pos += 1
	value, ok := strconv.parse_f64(p.source[start:p.pos])
	if !ok {fail(p, "malformed number"); return -1}
	if p.pos < len(p.source) && ident_char(p.source[p.pos]) {fail(p, "a number takes no unit"); return -1}
	return node(p, {op = .Number, a = -1, b = -1, number = value, integer = !strings.contains_rune(p.source[start:p.pos], '.')})
}

// Text as an expression literal: quoted, with \\, \" and newlines escaped.
quote :: proc(text: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for c in text {
		switch c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case:
			strings.write_rune(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}
