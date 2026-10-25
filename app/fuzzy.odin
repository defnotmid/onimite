package onimite_app

// onib's matcher (workflow/fuzzy.odin), as it is there.

import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The one matcher every filter, query and completion uses. A query is parts
// split on spaces, in any order (after RAD Debugger's); each part matches a
// label when its letters appear in it in order, any case, scored after fzy:
// a run of consecutive letters scores most, then a letter that starts a word
// (after a space, `.`, `_`, `-`, `/` or `[`, or a capital after a lowercase
// letter); every skipped letter costs a little, before the first match and
// after the last less than between. A label matches when every part does;
// its score is theirs summed. An empty query matches everything, scoring 0.
FUZZY_GAP_OUTER :: -0.005
FUZZY_GAP_INNER :: -0.01
FUZZY_CONSECUTIVE :: 1.0
FUZZY_START :: 0.9 // the label's first letter, or after `/`
FUZZY_WORD :: 0.8
FUZZY_CAPITAL :: 0.7
FUZZY_DOT :: 0.6
fuzzy_score :: proc(label, query: string) -> (score: f64, ok: bool) {
	ok = true
	for part in strings.fields(query, context.temp_allocator) {
		s, matched := fuzzy_part(label, part, nil)
		if !matched do return math.inf_f64(-1), false
		score += s
	}
	return
}
// Which of the label's letters (rune indices, ascending, each once) the
// query's parts matched, for a view to highlight.
fuzzy_positions :: proc(label, query: string) -> []int {
	marked := make([dynamic]bool, strings.rune_count(label), context.temp_allocator)
	for part in strings.fields(query, context.temp_allocator) {
		at := make([]int, strings.rune_count(part), context.temp_allocator)
		if _, ok := fuzzy_part(label, part, at); ok {for j in at do marked[j] = true}
	}
	out := make([dynamic]int, context.temp_allocator)
	for m, j in marked {if m do append(&out, j)}
	return out[:]
}
// One part's best alignment: its score, and with `positions` (one per
// letter of the part) where each letter fell.
fuzzy_part :: proc(label, part: string, positions: []int) -> (score: f64, ok: bool) {
	none := math.inf_f64(-1)
	if !text_matches(label, part) do return none, false
	l := make([dynamic]rune, 0, len(label), context.temp_allocator)
	for r in label do append(&l, r)
	q := make([dynamic]rune, 0, len(part), context.temp_allocator)
	for r in part do append(&q, unicode.to_lower(r))
	n, m := len(l), len(q)
	// Where each letter would start a word: its bonus as a match.
	bonus := make([]f64, n, context.temp_allocator)
	for j in 0 ..< n {
		switch {
		case j == 0 || l[j - 1] == '/':
			bonus[j] = FUZZY_START
		case l[j - 1] == ' ' || l[j - 1] == '_' || l[j - 1] == '-' || l[j - 1] == '[':
			bonus[j] = FUZZY_WORD
		case unicode.is_upper(l[j]) && unicode.is_lower(l[j - 1]):
			bonus[j] = FUZZY_CAPITAL
		case l[j - 1] == '.':
			bonus[j] = FUZZY_DOT
		}
	}
	// D[i][j]: the part's first i+1 letters with letter i on label letter j;
	// M[i][j]: the best of them anywhere up to j. All rows kept when the
	// positions are wanted (to walk back), else two.
	rows := positions != nil ? m : 2
	D := make([]f64, rows * n, context.temp_allocator)
	M := make([]f64, rows * n, context.temp_allocator)
	for i in 0 ..< m {
		cur, prev := (positions != nil ? i : i % 2) * n, (positions != nil ? i - 1 : (i + 1) % 2) * n
		best := none
		gap: f64 = i == m - 1 ? FUZZY_GAP_OUTER : FUZZY_GAP_INNER
		for j in 0 ..< n {
			if unicode.to_lower(l[j]) == q[i] {
				s := none
				if i == 0 {
					s = f64(j) * FUZZY_GAP_OUTER + bonus[j]
				} else if j > 0 {
					s = max(M[prev + j - 1] + bonus[j], D[prev + j - 1] + FUZZY_CONSECUTIVE)
				}
				D[cur + j] = s
				best = max(s, best + gap)
			} else {
				D[cur + j] = none
				best = best + gap
			}
			M[cur + j] = best
		}
	}
	last := (positions != nil ? m - 1 : (m - 1) % 2) * n
	score = M[last + n - 1]
	if score == none do return none, false
	if positions != nil {
		// Walk back from the end: a letter is where its score came from.
		required := false
		j := n - 1
		for i := m - 1; i >= 0; i -= 1 {
			for ; j >= 0; j -= 1 {
				row := i * n
				if D[row + j] != none && (required || D[row + j] == M[row + j]) {
					required = i > 0 && j > 0 && M[row + j] == D[row - n + j - 1] + FUZZY_CONSECUTIVE
					positions[i] = j
					j -= 1
					break
				}
			}
		}
	}
	return score, true
}
// `order` (indices into `scores`) sorted best first; equal scores keep their order.
fuzzy_rank :: proc(scores: []f64, order: []int) {
	for i in 1 ..< len(order) {
		v := order[i]; j := i
		for j > 0 && scores[order[j - 1]] < scores[v] {order[j] = order[j - 1]; j -= 1}
		order[j] = v
	}
}
// Whether `needle`'s letters appear in `haystack` in order, any case.
text_matches :: proc(haystack, needle: string) -> bool {
	remaining := needle
	for c in haystack {
		if len(remaining) == 0 do return true
		n, size := utf8.decode_rune(remaining)
		if unicode.to_lower(c) == unicode.to_lower(n) do remaining = remaining[size:]
	}
	return len(remaining) == 0
}
