package ui

// Keyboard focus as RAD Debugger's (ui_core.c): two stacks of focus kinds,
// hot (what the keys would act on) and active (what is taking them, as a
// field being edited). A box built while a stack's top is On is focus hot
// or active; it is disabled so when an Off lies below before a Root (a
// panel that isn't focused holds its views Off). Navigation roots keep which
// of their boxes is focused by key, set for the next frame and taken as the
// build begins (the auto-focus keys).
Focus_Kind :: enum u8 {
	Null, // as the scope around
	Off,
	On,
	Root, // a fresh scope: what is Off around it doesn't reach in
}

push_focus_hot :: proc(s: ^State, v: Focus_Kind) {append(&s.focus_hot.items, v)}
pop_focus_hot :: proc(s: ^State) {if len(s.focus_hot.items) > 0 do pop(&s.focus_hot.items)}
push_focus_active :: proc(s: ^State, v: Focus_Kind) {append(&s.focus_active.items, v)}
pop_focus_active :: proc(s: ^State) {if len(s.focus_active.items) > 0 do pop(&s.focus_active.items)}
set_next_focus_hot :: proc(s: ^State, v: Focus_Kind) {s.focus_hot.next = v}
set_next_focus_active :: proc(s: ^State, v: Focus_Kind) {s.focus_active.next = v}
// Both stacks, as RAD's UI_Focus.
push_focus :: proc(s: ^State, v: Focus_Kind) {push_focus_hot(s, v); push_focus_active(s, v)}
pop_focus :: proc(s: ^State) {pop_focus_hot(s); pop_focus_active(s)}

top_focus_hot :: proc(s: ^State) -> Focus_Kind {return s.focus_hot.next.? or_else stack_top(&s.focus_hot, Focus_Kind.Null)}
top_focus_active :: proc(s: ^State) -> Focus_Kind {return s.focus_active.next.? or_else stack_top(&s.focus_active, Focus_Kind.Null)}
// As RAD's ui_is_focus_hot / ui_is_focus_active: the top is On, and no Off
// lies below it before a Root.
is_focus_hot :: proc(s: ^State) -> bool {return focus_on(&s.focus_hot)}
is_focus_active :: proc(s: ^State) -> bool {return focus_on(&s.focus_active)}
@(private)
focus_on :: proc(stack: ^Stack(Focus_Kind)) -> bool {
	if (stack.next.? or_else stack_top(stack, Focus_Kind.Null)) != .On do return false
	#reverse for kind in stack.items {
		if kind == .Root do break
		if kind == .Off do return false
	}
	return true
}

// As RAD's ui_is_key_auto_focus_active / _hot: an ancestor navigation root,
// itself focused, names this key as its focused box.
is_key_auto_focus_active :: proc(s: ^State, key: Key) -> bool {
	if key == 0 do return false
	for p := top_parent(s); p != nil; p = p.parent {
		if .Focus_Active in p.flags && key == p.default_nav_focus_active_key do return true
	}
	return false
}
is_key_auto_focus_hot :: proc(s: ^State, key: Key) -> bool {
	if key == 0 do return false
	for p := top_parent(s); p != nil; p = p.parent {
		if .Focus_Hot in p.flags && (.Focus_Hot_Disabled not_in p.flags && key == p.default_nav_focus_hot_key || key == p.default_nav_focus_active_key) do return true
	}
	return false
}
// As RAD's ui_set_auto_focus_active_key / _hot_key: the nearest navigation
// root focuses `key` from the next frame (0: none).
set_auto_focus_active_key :: proc(s: ^State, key: Key) {
	for p := top_parent(s); p != nil; p = p.parent {
		if p.flags & DEFAULT_FOCUS_NAV != {} {p.default_nav_focus_next_active_key = key; return}
	}
}
set_auto_focus_hot_key :: proc(s: ^State, key: Key) {
	for p := top_parent(s); p != nil; p = p.parent {
		if p.flags & DEFAULT_FOCUS_NAV != {} {p.default_nav_focus_next_hot_key = key; return}
	}
}
DEFAULT_FOCUS_NAV :: Box_Flags{.Default_Focus_Nav_X, .Default_Focus_Nav_Y}

// A box's focus flags as build_box gives them (RAD's ui_build_box_from_key):
// focused by key, its stacks' tops say On for it; On is hot or active, and
// disabled where an Off lies below. The first navigation root built while
// focus is active is the one the keys navigate next frame.
@(private)
focus_flags :: proc(s: ^State, box: ^Box) {
	if is_focus_active(s) && box.flags & DEFAULT_FOCUS_NAV != {} && s.default_nav_root == 0 do s.default_nav_root = box.key
	if is_key_auto_focus_active(s, box.key) do set_next_focus_active(s, .On)
	if is_key_auto_focus_hot(s, box.key) do set_next_focus_hot(s, .On)
	if top_focus_hot(s) == .On {
		box.flags += {.Focus_Hot}
		if !is_focus_hot(s) do box.flags += {.Focus_Hot_Disabled}
	}
	if top_focus_active(s) == .On {
		box.flags += {.Focus_Active}
		if !is_focus_active(s) do box.flags += {.Focus_Active_Disabled}
	}
	s.focus_hot.next, s.focus_active.next = nil, nil
}

// As RAD's ui_begin_build default navigation: in the navigation root built
// last frame while focus was active, with none of its boxes active, a
// Navigate row along the axes it navigates moves its focus to the next or
// previous clickable box in tree order (an explicitly directional one along
// its axis only, to the box nearest across); with one active, cancel rows
// let go of the innermost active box.
default_nav_process :: proc(s: ^State) {
	if s.default_nav_root == 0 do return
	nav_root, ok := s.box_table[s.default_nav_root]
	if !ok do return
	if nav_root.default_nav_focus_active_key == 0 {
		focus_box := s.box_table[nav_root.default_nav_focus_next_hot_key] or_else nil
		next_, prev_ := false, false
		lock := -1
		for &a in s.actions.rows {
			if a.consumed || a.delta == {} do continue
			taken := false
			if (a.delta.x > 0 && .Default_Focus_Nav_X in nav_root.flags || a.delta.x == 0) && (a.delta.y > 0 && .Default_Focus_Nav_Y in nav_root.flags || a.delta.y == 0) {taken = true; next_ = true}
			if (a.delta.x < 0 && .Default_Focus_Nav_X in nav_root.flags || a.delta.x == 0) && (a.delta.y < 0 && .Default_Focus_Nav_Y in nav_root.flags || a.delta.y == 0) {taken = true; prev_ = true}
			if .Explicit_Directional in a.flags do lock = a.delta.x != 0 ? 0 : 1
			if taken do a.consumed = true
		}
		candidates := make([dynamic]^Box, context.temp_allocator)
		start := focus_box != nil ? focus_box : nav_root
		takes :: proc(box, start: ^Box, lock: int, moved: [2]int) -> bool {
			return box != start && (box == nil || .Focus_Nav_Skip not_in box.flags && .Clickable in box.flags) && (lock < 0 || moved[lock] > 0)
		}
		if next_ {
			moved: [2]int
			box := start
		for {
				if takes(box, start, lock, moved) {
					append(&candidates, box)
					if lock < 0 || moved[lock] > 1 do break
				}
				last := box
				if box.first != nil {
					moved[int(box.child_layout_axis)] += 1
					box = box.first
				} else {
					for p := box; p != nil && p != nav_root; p = p.parent {
						if p.next != nil {moved[int(p.parent.child_layout_axis)] += 1; box = p.next; break}
					}
				}
				if last == box {append(&candidates, nil); break}
			}
		}
		if prev_ {
			moved: [2]int
			box := start
		for {
				if takes(box, start, lock, moved) {
					append(&candidates, box)
					if lock < 0 || moved[lock] > 1 do break
				}
				last := box
				root_descendant, prev_descendant: ^Box
				if box == nav_root && box == start {
					for d := box.last; d != nil; d = d.last {moved[int(d.parent.child_layout_axis)] += 1; root_descendant = d}
				}
				for d := box.prev; d != nil; d = d.last {moved[int(d.parent.child_layout_axis)] += 1; prev_descendant = d}
				if root_descendant != nil {
					box = root_descendant
				} else if prev_descendant != nil {
					box = prev_descendant
				} else if box.parent != nav_root && box.parent != nil {
					moved[int(box.parent.child_layout_axis)] += 1
					box = box.parent
				}
				if box == last {append(&candidates, nil); break}
			}
		}
		// The candidate nearest across the locked axis.
		center :: proc(b: ^Box) -> [2]f32 {return b == nil ? {} : (b.rect.min + b.rect.max) / 2}
		chosen := focus_box
		best := f32(1000000)
		for box in candidates {
			distance := lock < 0 ? 0 : abs(center(box)[1 - lock] - center(focus_box)[1 - lock])
			if distance < best && box != focus_box {chosen = box; best = distance}
		}
		if next_ || prev_ do nav_root.default_nav_focus_next_hot_key = chosen != nil ? chosen.key : 0
	} else {
		for action_pressed(s, .Cancel) {
			prev := nav_root
			for focus_root := s.box_table[nav_root.default_nav_focus_active_key] or_else nil; focus_root != nil; {
				next_root := s.box_table[focus_root.default_nav_focus_active_key] or_else nil
				if next_root == nil {prev.default_nav_focus_next_active_key = 0; break}
				prev, focus_root = focus_root, next_root
			}
		}
	}
}
