// Package ui is an idiomatic-Odin port of the RAD Debugger immediate-mode UI
// framework (raddebugger/src/ui), copied from ../paf/ui (itself from
// odincade's sketch_and_extrude) with the preview's action vocabulary. It keeps the core semantics faithful:
//
//   - A box tree rebuilt every frame on the temp allocator. What a keyed
//     box keeps across frames (hot_t/active_t, last-frame rect) is a row of
//     `State.memories`, so animation/interaction state persists.
//   - UI_Size kinds: Pixels, Text_Content, Parent_Pct.
//   - The autolayout, run per-axis (X then Y): standalone sizes,
//     upwards-dependent (parent pct), violation solving (shrink by
//     strictness), then final positions.
//   - Interaction (`signal_from_box`) uses the box rect from the PREVIOUS
//     frame, which is standard immediate-mode behaviour.
//   - Platform input is gathered into contiguous per-frame action rows that
//     consumers claim explicitly.
//
// The C original leans on macros, an implicit thread-static state pointer, and
// intrusive nil-sentinel linked lists. This port instead threads an explicit
// `^State` to every proc, uses `bit_set` flags and flat rows of box memory
// found by key, and represents nil boxes by plain `nil`.
package ui

import "core:math"
import "core:strings"

import platform "../platform"
import render "../render"

////////////////////////////////
// Keys

// Key is a hashed 64-bit identity. Key(0) is the "zero"/nil key: a box with a
// zero key is transient (rebuilt fresh, not persisted, not interactive).
Key :: distinct u64

FNV_OFFSET :: 0xcbf29ce484222325
FNV_PRIME :: 0x00000100000001b3

// hash_string mixes `s` into the 64-bit `seed` via seeded FNV-1a. This mirrors
// raddbg's `u64_hash_from_seed_str8`: parent identity is folded in as the seed
// so equal display strings under different parents get distinct keys.
hash_string :: proc(seed: u64, s: string) -> u64 {
	h := seed == 0 ? u64(FNV_OFFSET) : seed
	for i in 0 ..< len(s) {
		h = (h ~ u64(s[i])) * FNV_PRIME
	}
	return h
}

// key_from_string derives a Key for `s` seeded by `seed`. Supports raddbg's
// `###` split: everything from `###` onward (inclusive of the marker) is what
// gets hashed, so display text can differ from identity. An empty hash part
// yields Key(0) (transient).
key_from_string :: proc(seed: Key, s: string) -> Key {
	hash_part := hash_part_from_string(s)
	if len(hash_part) == 0 {
		return Key(0)
	}
	return Key(hash_string(u64(seed), hash_part))
}

// hash_part_from_string returns the portion of `s` used for hashing: from the
// first `###` (inclusive) if present, else the whole string.
hash_part_from_string :: proc(s: string) -> string {
	if idx := strings.index(s, "###"); idx >= 0 {
		return s[idx:]
	}
	return s
}

// display_part_from_string returns the portion of `s` shown to the user:
// everything before the first `##` if present, else the whole string.
display_part_from_string :: proc(s: string) -> string {
	if idx := strings.index(s, "##"); idx >= 0 {
		return s[:idx]
	}
	return s
}

////////////////////////////////
// Geometry / sizing

Axis2 :: enum u8 {
	X,
	Y,
}

Size_Kind :: enum u8 {
	Null,
	Pixels, // exact pixel value
	Text_Content, // measured text width + padding
	Parent_Pct, // fraction of nearest fixed-size ancestor
}

Size :: struct {
	kind:       Size_Kind,
	value:      f32,
	strictness: f32, // 0 = fully squishable, 1 = never shrinks
}

// px / text_content / fill are the size constructors used by widgets and
// callers.
px :: proc(value: f32, strictness: f32 = 1) -> Size {
	return {.Pixels, value, strictness}
}

text_content :: proc(padding: f32 = 0, strictness: f32 = 1) -> Size {
	return {.Text_Content, padding, strictness}
}

// fill is a convenience: pref-size that expands to the parent (pct 1, fully
// squishable so siblings resolve violations).
fill :: proc() -> Size {
	return {.Parent_Pct, 1, 0}
}

////////////////////////////////
// Box flags & text alignment

Box_Flag :: enum u32 {
	Clickable, // participates in mouse hover/press/click
	Draw_Background,
	Draw_Image,
	Draw_Border,
	Draw_Text,
	Draw_Hot_Effects, // brighten toward hot_t
	Draw_Active_Effects, // brighten toward active_t
	Clip, // push a scissor rect equal to this box's rect
	Floating_X, // fixed_pos.x is absolute (set automatically by fixed_x)
	Floating_Y,
	Fixed_Width, // fixed_size.x is authoritative (bypasses pref_size)
	Fixed_Height,
	Drop_Site, // may become the drop-hot box while a drag is active
}

Box_Flags :: bit_set[Box_Flag;u32]

Text_Align :: enum u8 {
	Left,
	Center,
	Right,
}

////////////////////////////////
// Box

// Box is one node in the per-frame tree, on context.temp_allocator (the
// caller frees it after the frame). A keyed box starts from its memory
// (hot_t, active_t, rect from last frame) and writes it back at build_end;
// a transient one (Key 0) starts from nothing.
Box :: struct {
	// intrusive tree (per-frame; nil-terminated)
	first, last, next, prev, parent: ^Box,
	child_count:                     int,

	// identity / config (rebuilt each frame)
	key:                             Key,
	flags:                           Box_Flags,
	str:                             string, // display string (arena-owned this frame)
	text_align:                      Text_Align,
	pref_size:                       [Axis2]Size,
	child_layout_axis:               Axis2,
	fixed_pos:                       [2]f32, // used when Floating_X/Y
	fixed_size:                      [2]f32, // computed size, or authoritative when Fixed_*
	min_size:                        [2]f32,

	// appearance
	bg_color:                        [4]u8,
	text_color:                      [4]u8,
	hot_color:                       [4]u8,
	active_color:                    [4]u8,
	corner_radius:                   f32,
	border_thickness:                f32,
	font_size:                       f32,
	text_padding:                    f32,
	image:                           ^render.Image,
	// Drawn after the box's own background, border and text and before its
	// children, with the box's final rect (raddbg's custom draw function).
	// `custom_draw_data` must outlive build_end.
	custom_draw:                     Custom_Draw,
	custom_draw_data:                rawptr,

	// computed layout (rect.min/max in pixels)
	rect:                            Rect,

	// persistent state (from the box's memory; survives across frames)
	hot_t, active_t:                 f32,
	// The box's row of State.memories (-1: transient).
	memory:                          int,
}

Rect :: struct {
	min, max: [2]f32,
}

// What a keyed box keeps from one frame to the next.
Box_Memory :: struct {
	key:              Key,
	rect:             Rect,
	hot_t, active_t:  f32,
	last_build_index: u64,
}

Custom_Draw :: #type proc(s: ^State, box: ^Box, data: rawptr)

////////////////////////////////
// Signals

Sig_Flag :: enum u32 {
	Left_Pressed,
	Left_Clicked, // pressed then released while inside bounds
	Left_Dragging,
	Middle_Pressed,
	Middle_Dragging, // the middle button held since it pressed on this box
	Mouse_Over, // mouse is within rect (possibly occluded)
}

Sig_Flags :: bit_set[Sig_Flag;u32]

// Signal is the interaction result for a box, computed against the box's
// last-frame rect. `drag_delta` is mouse-now minus press-origin.
Signal :: struct {
	box:         ^Box,
	flags:       Sig_Flags,
	drag_delta:  [2]f32,
	// The mouse's movement this frame while the box is dragged (either
	// button).
	drag_motion: [2]f32,
	scroll:      f32,
	// Horizontal scrolling over the box (right positive).
	scroll_x:    f32,
	// Scrolling with Control held over the box: zoom steps (in positive).
	zoom:        f32,
}

clicked :: proc(s: Signal) -> bool {return .Left_Clicked in s.flags}
pressed :: proc(s: Signal) -> bool {return .Left_Pressed in s.flags}
mouse_over :: proc(s: Signal) -> bool {return .Mouse_Over in s.flags}
dragging :: proc(s: Signal) -> bool {return .Left_Dragging in s.flags}
middle_dragging :: proc(s: Signal) -> bool {return .Middle_Dragging in s.flags}

////////////////////////////////
// State

// State is the whole UI context. Create with `init`, destroy with `destroy`.
// One State per window/UI surface. Threaded explicitly to every proc.
State :: struct {
	r:               ^render.Renderer,
	p:               ^platform.Platform,
	font:            ^render.Font,

	// keyed boxes' memories, and their rows by key
	memories:        [dynamic]Box_Memory,
	memory_of_key:   map[Key]int,

	// build state
	root:            ^Box,
	build_index:     u64,

	// interaction
	hot:             Key,
	middle_active:   Key, // the box the middle button pressed on, while held
	drop_hot:        Key, // the Drop_Site box under the mouse this frame (raddbg's drop_hot_box_key)
	active:          Key, // left-button active (the pressed widget)
	drag_start:      [2]f32,
	actions:         Action_Storage,
	animations:      Animation_Storage,
	is_animating:    bool,

	parent_stack:    [dynamic]^Box,

	// set_next_* overrides, consumed by the next build_box
	next:            Box_Overrides,

	// theme defaults
	theme:           Theme,
}

// Theme holds default colors + metrics. Kept simple and public so callers can
// tweak it after `init`.
Theme :: struct {
	background:       [4]u8,
	panel:            [4]u8,
	text:             [4]u8,
	border:           [4]u8,
	hot:              [4]u8,
	active:           [4]u8,
	accent:           [4]u8,
	default_font_px:  f32,
	default_padding:  f32,
	default_corner:   f32,
	hot_anim_rate:    f32, // per-second approach rate toward target
	active_anim_rate: f32,
}

default_theme :: proc() -> Theme {
	return Theme {
		background = {24, 26, 32, 255},
		panel = {38, 42, 52, 255},
		text = {224, 228, 236, 255},
		border = {70, 78, 92, 255},
		hot = {60, 68, 84, 255},
		active = {90, 130, 200, 255},
		accent = {96, 150, 230, 255},
		default_font_px = 18,
		default_padding = 6,
		default_corner = 4,
		hot_anim_rate = 45,
		active_anim_rate = 55,
	}
}

// init wires a State to the renderer/platform/font and seeds the theme.
init :: proc(s: ^State, r: ^render.Renderer, p: ^platform.Platform, font: ^render.Font) {
	s.r = r
	s.p = p
	s.font = font
	s.memories = make([dynamic]Box_Memory)
	s.memory_of_key = make(map[Key]int)
	s.parent_stack = make([dynamic]^Box)
	s.actions = action_storage_make()
	s.animations = animation_storage_make()
	s.theme = default_theme()
	s.build_index = 0
}

// destroy frees the boxes' memories and the State's containers.
destroy :: proc(s: ^State) {
	delete(s.memories)
	delete(s.memory_of_key)
	delete(s.parent_stack)
	action_storage_destroy(&s.actions)
	animation_storage_destroy(&s.animations)
}

////////////////////////////////
// Build phase

// build_begin starts a frame: bumps build_index, clears the overrides, and
// pushes a framebuffer-sized root box. Interaction keys computed last frame
// carry over.
build_begin :: proc(s: ^State) {
	s.build_index += 1
	s.is_animating = false
	animation_storage_prune(&s.animations, s.build_index)
	actions_gather_from_platform(&s.actions, s.p)

	// reset the parents and overrides (they do not persist across frames)
	clear(&s.parent_stack)
	s.next = {}

	// reset hot each frame if nothing is being actively held (raddbg does the
	// same: hot is re-derived from mouse position during signal computation).
	if s.active == Key(0) {
		s.hot = Key(0)
	}
	// Drop-hot is re-derived every frame from the drop sites' signals.
	s.drop_hot = Key(0)

	// root box: fills the framebuffer, lays children along X by default.
	fbw := f32(s.p.width)
	fbh := f32(s.p.height)
	set_next_fixed_width(s, fbw)
	set_next_fixed_height(s, fbh)
	set_next_child_layout_axis(s, .X)
	root := build_box(s, {}, "###ui_root")
	root.rect.min = {0, 0}
	root.rect.max = {fbw, fbh}
	root.fixed_pos = {0, 0}
	s.root = root
	push_parent(s, root)
}

// build_end runs the layout passes (X then Y), draws the tree, keeps the
// keyed boxes' memories, then forgets the keys not built this frame.
build_end :: proc(s: ^State) {
	pop_parent(s) // pop root

	// autolayout, per axis.
	for axis in Axis2 {
		layout_standalone(s, s.root, axis)
		layout_upwards_dependent(s, s.root, axis)
		layout_enforce_constraints(s.root, axis)
		layout_position(s.root, axis)
	}

	// draw + animate
	draw(s)
	animations_advance(s)

	remember(s, s.root)
	prune(s)
}

// build_box creates (or reuses) a box for `string_key`. The key is derived
// from the nearest keyed ancestor's key (seed) so identity is stable and
// scoped. A `###` in the string separates display text from identity; a `##`
// separates display text from a non-identity suffix. Consumes all set_next_*
// overrides.
build_box :: proc(s: ^State, flags: Box_Flags, string_key: string) -> ^Box {
	parent := top_parent(s)

	key := key_from_string(active_seed_key(s), string_key)
	transient := key == Key(0)

	box := new(Box, context.temp_allocator)
	box.key = key
	box.memory = -1
	if !transient {
		memory, known := s.memory_of_key[key]
		if !known {
			memory = len(s.memories)
			append(&s.memories, Box_Memory{key = key})
			s.memory_of_key[key] = memory
		}
		// A key built twice in one frame: the second box is transient.
		if m := &s.memories[memory]; m.last_build_index != s.build_index {
			m.last_build_index = s.build_index
			box.memory = memory
			box.rect, box.hot_t, box.active_t = m.rect, m.hot_t, m.active_t
		}
	}

	// link into tree
	if parent != nil {
		if parent.last != nil {
			parent.last.next = box
			box.prev = parent.last
			parent.last = box
		} else {
			parent.first = box
			parent.last = box
		}
		parent.child_count += 1
		box.parent = parent
	}

	n := &s.next
	box.flags = flags

	// sizing: fixed_* override pref_size and set Floating/Fixed flags
	if fx, ok := n.fixed_x.?; ok {
		box.flags |= {.Floating_X}
		box.fixed_pos.x = fx
	}
	if fy, ok := n.fixed_y.?; ok {
		box.flags |= {.Floating_Y}
		box.fixed_pos.y = fy
	}
	if fw, ok := n.fixed_width.?; ok {
		box.flags |= {.Fixed_Width}
		box.fixed_size.x = fw
	} else {
		box.pref_size[.X] = n.pref_width.? or_else text_content()
	}
	if fh, ok := n.fixed_height.?; ok {
		box.flags |= {.Fixed_Height}
		box.fixed_size.y = fh
	} else {
		box.pref_size[.Y] = n.pref_height.? or_else text_content()
	}

	box.child_layout_axis = n.child_layout_axis.? or_else .Y
	box.text_align = n.text_align.? or_else .Left
	box.font_size = n.font_size.? or_else s.theme.default_font_px
	box.text_padding = n.text_padding.? or_else s.theme.default_padding
	box.corner_radius = n.corner_radius.? or_else s.theme.default_corner
	box.bg_color = n.bg_color.? or_else s.theme.panel
	box.text_color = n.text_color.? or_else s.theme.text
	n^ = {}
	box.hot_color = s.theme.hot
	box.active_color = s.theme.active
	box.border_thickness = 1
	box.min_size = {0, 0}
	box.custom_draw = nil
	box.custom_draw_data = nil

	// display string (arena-lived for the frame via strings.clone in temp allocator)
	if .Draw_Text in box.flags {
		box.str = display_part_from_string(string_key)
	} else {
		box.str = ""
	}

	return box
}

// active_seed_key finds the nearest keyed ancestor on the parent stack and
// returns its key, used as the hash seed so identical strings under different
// parents produce different keys.
active_seed_key :: proc(s: ^State) -> Key {
	for i := len(s.parent_stack) - 1; i >= 0; i -= 1 {
		p := s.parent_stack[i]
		if p.key != Key(0) {
			return p.key
		}
	}
	return Key(0)
}

// Writes the keyed boxes' state back to their memories.
remember :: proc(s: ^State, box: ^Box) {
	if box.memory >= 0 {
		m := &s.memories[box.memory]
		m.rect, m.hot_t, m.active_t = box.rect, box.hot_t, box.active_t
	}
	for c := box.first; c != nil; c = c.next {
		remember(s, c)
	}
}

// Forgets the memories of keys not built this frame (the last row moves
// into a forgotten one's place).
prune :: proc(s: ^State) {
	for i := 0; i < len(s.memories); {
		m := s.memories[i]
		if m.last_build_index == s.build_index {
			i += 1
			continue
		}
		delete_key(&s.memory_of_key, m.key)
		last := pop(&s.memories)
		if i < len(s.memories) {
			s.memories[i] = last
			s.memory_of_key[last.key] = i
		}
	}
}

////////////////////////////////
// Parent stack

push_parent :: proc(s: ^State, b: ^Box) {
	append(&s.parent_stack, b)
}

pop_parent :: proc(s: ^State) {
	if len(s.parent_stack) > 0 {
		pop(&s.parent_stack)
	}
}

top_parent :: proc(s: ^State) -> ^Box {
	if len(s.parent_stack) > 0 {
		return s.parent_stack[len(s.parent_stack) - 1]
	}
	return nil
}

////////////////////////////////
// Layout passes (raddbg ui_layout_root without its children-sum pass)

// pass 1: standalone sizes (pixels, text content). Fixed_* already set size.
layout_standalone :: proc(s: ^State, box: ^Box, axis: Axis2) {
	if axis == .X && .Fixed_Width in box.flags {
		// already set
	} else if axis == .Y && .Fixed_Height in box.flags {
		// already set
	} else {
		#partial switch box.pref_size[axis].kind {
		case .Pixels:
			box.fixed_size[axis] = box.pref_size[axis].value
		case .Text_Content:
			pad := box.pref_size[axis].value
			if axis == .X {
				tw := render.measure_text(s.font, box.str, box.font_size)
				box.fixed_size[axis] = pad + tw + box.text_padding * 2
			} else {
				lh := render.line_height(s.font, box.font_size)
				box.fixed_size[axis] = pad + lh + box.text_padding * 2
			}
		}
	}
	for c := box.first; c != nil; c = c.next {
		layout_standalone(s, c, axis)
	}
}

// pass 2: upwards-dependent (parent pct of nearest fixed-size ancestor).
layout_upwards_dependent :: proc(s: ^State, box: ^Box, axis: Axis2) {
	if box.pref_size[axis].kind == .Parent_Pct {
		fixed_parent: ^Box
		for p := box.parent; p != nil; p = p.parent {
			fixed :=
				(axis == .X && .Fixed_Width in p.flags) || (axis == .Y && .Fixed_Height in p.flags)
			if fixed ||
			   p.pref_size[axis].kind == .Pixels ||
			   p.pref_size[axis].kind == .Text_Content ||
			   p.pref_size[axis].kind == .Parent_Pct {
				fixed_parent = p
				break
			}
		}
		if fixed_parent != nil {
			box.fixed_size[axis] = fixed_parent.fixed_size[axis] * box.pref_size[axis].value
		}
	}
	for c := box.first; c != nil; c = c.next {
		layout_upwards_dependent(s, c, axis)
	}
}

is_floating :: proc(b: ^Box, axis: Axis2) -> bool {
	if axis == .X {
		return .Floating_X in b.flags
	}
	return .Floating_Y in b.flags
}

// pass 3: solve violations. Along the layout axis, shrink children in
// proportion to (size * (1-strictness)); off-axis, clamp each child to parent.
layout_enforce_constraints :: proc(box: ^Box, axis: Axis2) {
	// off-axis: clamp each child to the parent's size
	if axis != box.child_layout_axis {
		allowed := box.fixed_size[axis]
		for c := box.first; c != nil; c = c.next {
			if is_floating(c, axis) {
				continue
			}
			violation := c.fixed_size[axis] - allowed
			fixup := clamp(violation, 0, c.fixed_size[axis])
			if fixup > 0 {
				c.fixed_size[axis] -= fixup
			}
		}
	}

	// layout axis: distribute the total violation across squishable children
	if axis == box.child_layout_axis {
		total_allowed := box.fixed_size[axis]
		total_size: f32 = 0
		total_weighted: f32 = 0
		for c := box.first; c != nil; c = c.next {
			if is_floating(c, axis) {
				continue
			}
			total_size += c.fixed_size[axis]
			total_weighted += c.fixed_size[axis] * (1 - c.pref_size[axis].strictness)
		}
		violation := total_size - total_allowed
		if violation > 0 && total_weighted > 0 {
			for c := box.first; c != nil; c = c.next {
				if is_floating(c, axis) {
					continue
				}
				fixup_this := max(c.fixed_size[axis] * (1 - c.pref_size[axis].strictness), 0)
				fixup_pct := clamp(violation / total_weighted, 0, 1)
				c.fixed_size[axis] -= fixup_this * fixup_pct
			}
		}
	}

	// enforce min sizes
	for c := box.first; c != nil; c = c.next {
		c.fixed_size[axis] = max(c.fixed_size[axis], c.min_size[axis])
	}

	for c := box.first; c != nil; c = c.next {
		layout_enforce_constraints(c, axis)
	}
}

// pass 4: compute final rects. Children stack along the parent's layout axis;
// floating children use their fixed_pos.
layout_position :: proc(box: ^Box, axis: Axis2) {
	layout_pos: f32 = 0
	for c := box.first; c != nil; c = c.next {
		if !is_floating(c, axis) {
			c.fixed_pos[axis] = layout_pos
			if box.child_layout_axis == axis {
				layout_pos += c.fixed_size[axis]
			}
		}
		c.rect.min[axis] = box.rect.min[axis] + c.fixed_pos[axis]
		c.rect.max[axis] = c.rect.min[axis] + c.fixed_size[axis]
		// floor to whole pixels (raddbg does this to avoid text shimmer)
		c.rect.min[axis] = math.floor(c.rect.min[axis])
		c.rect.max[axis] = math.floor(c.rect.max[axis])
	}
	for c := box.first; c != nil; c = c.next {
		layout_position(c, axis)
	}
}

////////////////////////////////
// Signal computation
//
// Faithful to raddbg ui_signal_from_box: interaction is resolved against the
// box's rect FROM LAST FRAME (this frame's rect is not yet final when widgets
// query signals). Mouse position + edge-detected buttons come from platform.

signal_from_box :: proc(s: ^State, box: ^Box) -> Signal {
	sig := Signal {
		box = box,
	}
	if box == nil {
		return sig
	}

	// clipped rect: intersect with any clipping ancestor
	r_min := box.rect.min
	r_max := box.rect.max
	for b := box.parent; b != nil; b = b.parent {
		if .Clip in b.flags {
			r_min.x = max(r_min.x, b.rect.min.x)
			r_min.y = max(r_min.y, b.rect.min.y)
			r_max.x = min(r_max.x, b.rect.max.x)
			r_max.y = min(r_max.y, b.rect.max.y)
		}
	}

	mp := platform.mouse_pos(s.p)
	in_bounds := mp.x >= r_min.x && mp.x < r_max.x && mp.y >= r_min.y && mp.y < r_max.y

	if in_bounds {
		sig.flags |= {.Mouse_Over}
	}

	// Like RAD Debugger's UI_EventKind_Scroll path, the hovered box consumes
	// the admitted scroll row. Sibling widgets and the camera cannot replay it.
	sig.scroll = action_scroll_consume(s, false, r_min, r_max)
	sig.scroll_x = action_scroll_consume(s, false, r_min, r_max, horizontal = true)
	sig.zoom = action_scroll_consume(s, true, r_min, r_max)

	// Drop sites: the first site under the mouse this frame owns the drop-hot
	// key, so a site built earlier (a panel's edge) wins over one built later
	// around it (the panel's centre).
	if .Drop_Site in box.flags && box.key != Key(0) && in_bounds && s.drop_hot == Key(0) {
		s.drop_hot = box.key
	}

	if .Clickable not_in box.flags {
		return sig
	}

	// left press inside -> become hot + active, record drag origin
	if platform.mouse_pressed(s.p, .Left) && in_bounds {
		s.hot = box.key
		s.active = box.key
		s.drag_start = mp
		sig.flags |= {.Left_Pressed}
	}
	if platform.mouse_pressed(s.p, .Middle) && in_bounds {
		sig.flags |= {.Middle_Pressed}
		s.middle_active = box.key
	}
	if s.middle_active == box.key {
		if platform.mouse_down(s.p, .Middle) || .Middle_Pressed in sig.flags {
			sig.flags |= {.Middle_Dragging}
		} else {
			s.middle_active = Key(0)
		}
	}

	// The drag delta is measured while this box is active, including on
	// the frame it is released: a sweep that ends needs to know where it
	// began, so the delta is taken before the release retires the box.
	if s.active == box.key || .Left_Pressed in sig.flags {
		sig.drag_delta = {mp.x - s.drag_start.x, mp.y - s.drag_start.y}
	}

	// left release while active
	if platform.mouse_released(s.p, .Left) && s.active == box.key {
		if in_bounds {
			sig.flags |= {.Left_Clicked}
		} else {
			s.hot = Key(0)
		}
		s.active = Key(0)
	}
	// active box (held) -> dragging
	if s.active == box.key || .Left_Pressed in sig.flags {
		if platform.mouse_down(s.p, .Left) || .Left_Pressed in sig.flags {
			sig.flags |= {.Left_Dragging}
		}
	}

	if sig.flags & {.Left_Dragging, .Middle_Dragging} != {} {
		sig.drag_motion = platform.mouse_delta(s.p)
	}

	// hover: mouse over and no other box owns hot/active
	if in_bounds &&
	   (s.hot == Key(0) || s.hot == box.key) &&
	   (s.active == Key(0) || s.active == box.key) {
		s.hot = box.key
	}

	return sig
}
