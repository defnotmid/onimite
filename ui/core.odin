// Package ui is an idiomatic-Odin port of the RAD Debugger immediate-mode UI
// framework (raddebugger/src/ui). It keeps the core semantics faithful:
//
//   - A persistent, keyed box tree rebuilt every frame. Keyed boxes survive
//     across frames in `State.box_table`, so animation/interaction state
//     (hot_t/active_t, last-frame rect) persists.
//   - UI_Size kinds: Pixels, Text_Content, Parent_Pct, Children_Sum.
//   - The 5-pass autolayout, run per-axis (X then Y): standalone sizes,
//     upwards-dependent (parent pct), downwards-dependent (children sum),
//     violation solving (shrink by strictness), then final positions.
//   - Interaction (`signal_from_box`) uses the box rect from the PREVIOUS
//     frame, which is standard immediate-mode behaviour.
//   - Platform input is gathered into contiguous per-frame action rows. Keyed
//     navigation roots consume those rows through the rebuilt box hierarchy.
//
// The C original leans on macros, an implicit thread-static state pointer, and
// intrusive nil-sentinel linked lists. This port instead threads an explicit
// `^State` to every proc, uses `bit_set` flags, `map[Key]^Box`, and Odin
// `@(deferred_in=...)` scope guards. Nil boxes are represented by plain `nil`.
package ui

import "../animation"
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

axis_flip :: proc(a: Axis2) -> Axis2 {
	return a == .X ? .Y : .X
}

Size_Kind :: enum u8 {
	Null,
	Pixels, // exact pixel value
	Text_Content, // measured text width + padding
	Parent_Pct, // fraction of nearest fixed-size ancestor
	Children_Sum, // sum (layout axis) / max (off-axis) of children
}

Size :: struct {
	kind:       Size_Kind,
	value:      f32,
	strictness: f32, // 0 = fully squishable, 1 = never shrinks
}

// px / pct / text_content / children_sum are the size constructors used by
// widgets and callers.
px :: proc(value: f32, strictness: f32 = 1) -> Size {
	return {.Pixels, value, strictness}
}

pct :: proc(value: f32, strictness: f32 = 0) -> Size {
	return {.Parent_Pct, value, strictness}
}

text_content :: proc(padding: f32 = 0, strictness: f32 = 1) -> Size {
	return {.Text_Content, padding, strictness}
}

children_sum :: proc(strictness: f32 = 1) -> Size {
	return {.Children_Sum, 0, strictness}
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
	Drop_Site, // first compatible site under the pointer owns the drop
	Click_To_Focus, // mouse press selects this box in its nearest nav root
	Default_Focus_Nav_X,
	Default_Focus_Nav_Y,
	Modal_Input_Root,
	Focus_Nav_Skip,
	Draw_Background,
	Draw_Horizontal_Gradient,
	Draw_Image, // onimite: `image`, contained in the box
	Draw_Border,
	Draw_Text,
	Draw_Hot_Effects, // brighten toward hot_t
	Draw_Active_Effects, // brighten toward active_t
	Clip, // push a scissor rect equal to this box's rect
	Floating_X, // fixed_pos.x is absolute (set automatically by fixed_x)
	Floating_Y,
	Fixed_Width, // fixed_size.x is authoritative (bypasses pref_size)
	Fixed_Height,
}

Box_Flags :: bit_set[Box_Flag;u32]

Text_Align :: enum u8 {
	Left,
	Center,
	Right,
}

////////////////////////////////
// Box

// Box is one node in the per-frame tree. Keyed boxes are heap-allocated once
// and reused across frames (found via State.box_table); transient boxes
// (Key 0) live in State.frame_boxes and are freed each frame. Per-frame fields
// (links, sizes, rect target) are reset by build_box; persistent fields
// (hot_t, active_t, rect from last frame) survive.
Custom_Draw :: #type proc(s: ^State, box: ^Box, data: rawptr) // onimite

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
	gradient_left:                   [4]u8,
	gradient_right:                  [4]u8,
	text_color:                      [4]u8,
	border_color:                    [4]u8,
	hot_color:                       [4]u8,
	active_color:                    [4]u8,
	corner_radius:                   f32,
	border_thickness:                f32,
	font_size:                       f32,
	text_padding:                    f32,
	text_width:                      f32,
	text_height:                     f32,
	text_slot:                       int, // its text laid out this frame (render.text_slot), once measured
	text_metrics_valid:              bool,
	opacity:                         f32,
	// onimite: an image drawn contained in the box (Draw_Image), and a
	// procedure drawn after the box's own background, border and text and
	// before its children, with the box's final rect (raddbg's custom draw);
	// `custom_draw_data` must outlive build_end.
	image:                           ^render.Image,
	custom_draw:                     Custom_Draw,
	custom_draw_data:                rawptr,

	// computed layout (rect.min/max in pixels)
	rect:                            struct {
		min, max: [2]f32,
	},

	// persistent state (survives across frames)
	hot_t, active_t:                 f32,
	first_build_index:               u64,
	last_build_index:                u64,
	transient:                       bool, // Key 0: lives in frame arena
	default_nav_focus_hot_key:       Key,
	default_nav_focus_active_key:    Key,
}

box_size :: proc(b: ^Box) -> [2]f32 {
	return {b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y}
}

////////////////////////////////
// Signals

Sig_Flag :: enum u32 {
	Left_Pressed,
	Left_Released,
	Left_Clicked, // pressed then released while inside bounds
	Left_Dragging,
	Right_Pressed,
	Right_Clicked,
	Middle_Pressed,
	Middle_Clicked,
	// onimite: the middle and right buttons held since they pressed on this
	// box (the timeline and the video pan by them).
	Middle_Dragging,
	Right_Dragging,
	Hovering, // this box owns the hot key this frame
	Mouse_Over, // mouse is within rect (possibly occluded)
	Keyboard_Pressed,
}

Sig_Flags :: bit_set[Sig_Flag;u32]

// Signal is the interaction result for a box, computed against the box's
// last-frame rect. `drag_delta` is mouse-now minus press-origin.
Signal :: struct {
	box:        ^Box,
	flags:      Sig_Flags,
	drag_delta: [2]f32,
	scroll:     f32,
	// onimite: the mouse's movement this frame while the box is dragged
	// (any button), horizontal scrolling over it (right positive), and
	// scrolling with Control held over it (zoom steps, in positive).
	drag_motion: [2]f32,
	scroll_x:    f32,
	zoom:        f32,
}

clicked :: proc(s: Signal) -> bool {return(
		.Left_Clicked in s.flags ||
		.Keyboard_Pressed in s.flags \
	)}
pressed :: proc(s: Signal) -> bool {return .Left_Pressed in s.flags}
released :: proc(s: Signal) -> bool {return .Left_Released in s.flags}
hovering :: proc(s: Signal) -> bool {return .Hovering in s.flags}
mouse_over :: proc(s: Signal) -> bool {return .Mouse_Over in s.flags}
dragging :: proc(s: Signal) -> bool {return .Left_Dragging in s.flags}
right_clicked :: proc(s: Signal) -> bool {return .Right_Clicked in s.flags}
middle_dragging :: proc(s: Signal) -> bool {return .Middle_Dragging in s.flags} // onimite
right_dragging :: proc(s: Signal) -> bool {return .Right_Dragging in s.flags} // onimite

////////////////////////////////
// Per-attribute stacks
//
// raddbg keeps a linked-stack per configurable attribute, with a "next" value
// consumed by the following box. This port keeps a small [dynamic] stack per
// attribute plus an optional one-shot "next" override, which is the ergonomic
// heart of the API (see scope guards below).

Stack :: struct($T: typeid) {
	items: [dynamic]T,
	next:  Maybe(T), // set by set_next_*, consumed by the next build_box
}

stack_top :: proc(s: ^Stack($T), fallback: T) -> T {
	if len(s.items) > 0 {
		return s.items[len(s.items) - 1]
	}
	return fallback
}

stack_has_override :: proc(s: ^Stack($T)) -> bool {
	_, has_next := s.next.?
	return has_next || len(s.items) > 0
}

// stack_use returns the value the next box should take: the one-shot `next`
// override if present (and clears it), otherwise the current top / fallback.
stack_use :: proc(s: ^Stack($T), fallback: T) -> T {
	if v, ok := s.next.?; ok {
		s.next = nil
		return v
	}
	return stack_top(s, fallback)
}

////////////////////////////////
// State

// State is the whole UI context. Create with `init`, destroy with `destroy`.
// One State per window/UI surface. Threaded explicitly to every proc.
State :: struct {
	r:                  ^render.Renderer,
	p:                  ^platform.Platform,
	font:               ^render.Font,

	// persistent keyed boxes
	box_table:          map[Key]^Box,

	// per-frame transient boxes (Key 0), freed at build_begin
	frame_boxes:        [dynamic]^Box,

	// build state
	root:               ^Box,
	build_index:        u64,
	build_box_count:    int,

	// interaction
	hot:                Key,
	hint:               string,
	drop_hot:           Key,
	active:             Key, // left-button active (the pressed widget)
	keyboard_focus:     Key,
	drag_start:         [2]f32,
	// onimite: the boxes the middle and right buttons pressed on.
	middle_active:      Key,
	right_active:       Key,
	actions:            Action_Storage,
	animations:         Animation_Storage,
	is_animating:       bool,
	modal_input_active: bool,
	font_scale:         f32,
	font_motion:        animation.Track,
	default_nav_root:   Key,

	// parent stack (explicit; not folded into the generic stacks)
	parent_stack:       [dynamic]^Box,

	// per-attribute stacks
	pref_width:         Stack(Size),
	pref_height:        Stack(Size),
	flags:              Stack(Box_Flags),
	child_layout_axis:  Stack(Axis2),
	fixed_x:            Stack(f32),
	fixed_y:            Stack(f32),
	fixed_width:        Stack(f32),
	fixed_height:       Stack(f32),
	text_align:         Stack(Text_Align),
	bg_color:           Stack([4]u8),
	text_color:         Stack([4]u8),
	border_color:       Stack([4]u8),
	corner_radius:      Stack(f32),
	font_size:          Stack(f32),
	text_padding:       Stack(f32),
	opacity:            Stack(f32),

	// theme defaults
	theme:              Theme,
}

box_in_modal_input_scope :: proc(box: ^Box) -> bool {
	for ancestor := box; ancestor != nil; ancestor = ancestor.parent {
		if .Modal_Input_Root in ancestor.flags {
			return true
		}
	}
	return false
}

key_is_in_modal_input_scope :: proc(s: ^State, key: Key) -> bool {
	if s == nil || key == Key(0) {
		return false
	}
	box, ok := s.box_table[key]
	return ok && box_in_modal_input_scope(box)
}

modal_input_set :: proc(s: ^State, active: bool) {
	if s == nil {
		return
	}
	if active && !s.modal_input_active {
		if !key_is_in_modal_input_scope(s, s.keyboard_focus) {
			s.keyboard_focus = Key(0)
		}
		if !key_is_in_modal_input_scope(s, s.hot) {
			s.hot = Key(0)
		}
		if !key_is_in_modal_input_scope(s, s.active) {
			s.active = Key(0)
		}
		s.default_nav_root = Key(0)
	}
	s.modal_input_active = active
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
	s.box_table = make(map[Key]^Box)
	s.frame_boxes = make([dynamic]^Box)
	s.parent_stack = make([dynamic]^Box)
	s.actions = action_storage_make()
	s.animations = animation_storage_make()
	s.theme = default_theme()
	s.font_scale = 1
	s.build_index = 0
}

// destroy frees all persistent boxes and the State's containers.
destroy :: proc(s: ^State) {
	for _, b in s.box_table {
		free(b)
	}
	delete(s.box_table)
	for b in s.frame_boxes {
		free(b)
	}
	delete(s.frame_boxes)
	delete(s.parent_stack)
	action_storage_destroy(&s.actions)
	animation_storage_destroy(&s.animations)
	stacks_delete(s)
}

stacks_delete :: proc(s: ^State) {
	delete(s.pref_width.items)
	delete(s.pref_height.items)
	delete(s.flags.items)
	delete(s.child_layout_axis.items)
	delete(s.fixed_x.items)
	delete(s.fixed_y.items)
	delete(s.fixed_width.items)
	delete(s.fixed_height.items)
	delete(s.text_align.items)
	delete(s.bg_color.items)
	delete(s.text_color.items)
	delete(s.border_color.items)
	delete(s.corner_radius.items)
	delete(s.font_size.items)
	delete(s.text_padding.items)
	delete(s.opacity.items)
}

////////////////////////////////
// Build phase

// build_begin starts a frame: bumps build_index, frees last frame's transient
// boxes, clears stacks, and pushes a framebuffer-sized root box. Interaction
// keys computed last frame carry over.
build_begin :: proc(s: ^State) {
	s.build_index += 1
	s.build_box_count = 0
	if s.font != nil && s.font.text != nil do render.font_frame(s.font)
	s.is_animating = false
	s.hint = ""
	animation_storage_prune(&s.animations, s.build_index)
	actions_gather_from_platform(&s.actions, s.p)
	font_scale_process_actions(s)
	default_nav_process_actions(s)
	s.default_nav_root = Key(0)

	// free transient boxes from previous frame
	for b in s.frame_boxes {
		free(b)
	}
	clear(&s.frame_boxes)

	// reset stacks (values do not persist across frames)
	clear(&s.parent_stack)
	stack_reset(&s.pref_width)
	stack_reset(&s.pref_height)
	stack_reset(&s.flags)
	stack_reset(&s.child_layout_axis)
	stack_reset(&s.fixed_x)
	stack_reset(&s.fixed_y)
	stack_reset(&s.fixed_width)
	stack_reset(&s.fixed_height)
	stack_reset(&s.text_align)
	stack_reset(&s.bg_color)
	stack_reset(&s.text_color)
	stack_reset(&s.border_color)
	stack_reset(&s.corner_radius)
	stack_reset(&s.font_size)
	stack_reset(&s.text_padding)
	stack_reset(&s.opacity)

	// reset hot each frame if nothing is being actively held (raddbg does the
	s.drop_hot = 0
	// same: hot is re-derived from mouse position during signal computation).
	if s.active == Key(0) {
		s.hot = Key(0)
	}

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

stack_reset :: proc(s: ^Stack($T)) {
	clear(&s.items)
	s.next = nil
}

// build_end runs the 5-pass layout (X then Y), draws the tree, then prunes any
// keyed box not touched this frame.
build_end :: proc(s: ^State) {
	pop_parent(s) // pop root

	// 5-pass autolayout, per axis.
	for axis in Axis2 {
		layout_standalone(s, s.root, axis)
		layout_upwards_dependent(s, s.root, axis)
		layout_downwards_dependent(s.root, axis)
		layout_enforce_constraints(s.root, axis)
		layout_position(s.root, axis)
	}

	// draw + animate
	draw(s)
	hint_draw(s)
	animations_advance(s)

	// prune keyed boxes untouched this frame
	prune(s)
}

// build_box creates (or reuses) a box for `string_key`. The key is derived
// from the nearest keyed ancestor's key (seed) so identity is stable and
// scoped. A `###` in the string separates display text from identity; a `##`
// separates display text from a non-identity suffix. Consumes all set_next_*
// overrides and the current attribute-stack tops.
build_box :: proc(s: ^State, flags: Box_Flags, string_key: string) -> ^Box {
	s.build_box_count += 1
	parent := top_parent(s)

	key := key_from_string(active_seed_key(s), string_key)
	transient := key == Key(0)

	box: ^Box
	if !transient {
		if existing, ok := s.box_table[key]; ok {
			// duplicate key within one frame -> demote to transient
			if existing.last_build_index == s.build_index {
				transient = true
			} else {
				box = existing
			}
		}
	}

	first_frame := false
	if box == nil {
		box = new(Box)
		first_frame = true
		if transient {
			box.transient = true
			append(&s.frame_boxes, box)
		} else {
			box.first_build_index = s.build_index
			s.box_table[key] = box
		}
	}

	// reset per-frame fields (preserve persistent hot_t/active_t/rect)
	box.first = nil
	box.image, box.custom_draw, box.custom_draw_data = nil, nil, nil // onimite
	box.last = nil
	box.next = nil
	box.prev = nil
	box.parent = nil
	box.child_count = 0
	box.key = key
	box.text_metrics_valid = false

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

	// flags: OR the pushed-flags stack with the explicit arg
	box.flags = flags | stack_use(&s.flags, Box_Flags{})

	// sizing: fixed_* stacks override pref_size and set Floating/Fixed flags
	if fx, ok := s.fixed_x.next.?; ok {
		box.flags |= {.Floating_X}
		box.fixed_pos.x = fx
		s.fixed_x.next = nil
	} else if fx2, ok2 := stack_maybe_top(&s.fixed_x); ok2 {
		box.flags |= {.Floating_X}
		box.fixed_pos.x = fx2
	}
	if fy, ok := s.fixed_y.next.?; ok {
		box.flags |= {.Floating_Y}
		box.fixed_pos.y = fy
		s.fixed_y.next = nil
	} else if fy2, ok2 := stack_maybe_top(&s.fixed_y); ok2 {
		box.flags |= {.Floating_Y}
		box.fixed_pos.y = fy2
	}

	if fw, ok := stack_maybe_use(&s.fixed_width); ok {
		box.flags |= {.Fixed_Width}
		box.fixed_size.x = fw
	} else {
		box.pref_size[.X] = stack_use(&s.pref_width, text_content())
	}
	if fh, ok := stack_maybe_use(&s.fixed_height); ok {
		box.flags |= {.Fixed_Height}
		box.fixed_size.y = fh
	} else {
		box.pref_size[.Y] = stack_use(&s.pref_height, text_content())
	}

	box.child_layout_axis = stack_use(&s.child_layout_axis, Axis2.Y)
	box.text_align = stack_use(&s.text_align, Text_Align.Left)
	box.font_size = stack_use(&s.font_size, s.theme.default_font_px) * s.font_scale
	box.text_padding = stack_use(&s.text_padding, s.theme.default_padding)
	box.opacity = stack_use(&s.opacity, 1)
	box.corner_radius = stack_use(&s.corner_radius, s.theme.default_corner)
	box.bg_color = stack_use(&s.bg_color, s.theme.panel)
	box.gradient_left = box.bg_color
	box.gradient_right = box.bg_color
	box.text_color = stack_use(&s.text_color, s.theme.text)
	box.border_color = stack_use(&s.border_color, s.theme.border)
	box.hot_color = s.theme.hot
	box.active_color = s.theme.active
	box.border_thickness = 1
	box.min_size = {0, 0}

	// display string (arena-lived for the frame via strings.clone in temp allocator)
	if .Draw_Text in box.flags {
		box.str = display_part_from_string(string_key)
	} else {
		box.str = ""
	}

	if !transient {
		box.last_build_index = s.build_index
	} else {
		box.last_build_index = s.build_index
	}
	_ = first_frame

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

stack_maybe_top :: proc(s: ^Stack($T)) -> (T, bool) {
	if len(s.items) > 0 {
		return s.items[len(s.items) - 1], true
	}
	return {}, false
}

// stack_maybe_use returns the one-shot `next` value if present (clearing it),
// else the top of the stack if any. Used for fixed_* which must not fall back
// to a default (their absence means "not fixed").
stack_maybe_use :: proc(s: ^Stack($T)) -> (T, bool) {
	if v, ok := s.next.?; ok {
		s.next = nil
		return v, true
	}
	return stack_maybe_top(s)
}

box_from_key :: proc(s: ^State, key: Key) -> ^Box {
	if key == Key(0) {
		return nil
	}
	return s.box_table[key]
}

// prune removes keyed boxes whose last_build_index is stale.
prune :: proc(s: ^State) {
	to_remove := make([dynamic]Key, context.temp_allocator)
	for k, b in s.box_table {
		if b.last_build_index != s.build_index {
			append(&to_remove, k)
		}
	}
	for k in to_remove {
		b := s.box_table[k]
		free(b)
		delete_key(&s.box_table, k)
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
// Layout: 5 passes (faithful to raddbg ui_layout_root)

box_text_metrics_ensure :: #force_inline proc(s: ^State, box: ^Box) {
	if box.text_metrics_valid do return
	// Laid out once a frame: measured here, drawn from the same layout.
	box.text_slot = render.text_slot(s.font, box.str, box.font_size)
	box.text_width = render.slot_width(s.font, box.text_slot)
	box.text_height = render.line_height(s.font, box.font_size)
	box.text_metrics_valid = true
}

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
			box_text_metrics_ensure(s, box)
			if axis == .X {
				box.fixed_size[axis] = pad + box.text_width + box.text_padding * 2
			} else {
				box.fixed_size[axis] = pad + box.text_height + box.text_padding * 2
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

// pass 3: downwards-dependent (children sum / max). Post-order so children are
// sized before parents.
layout_downwards_dependent :: proc(box: ^Box, axis: Axis2) {
	for c := box.first; c != nil; c = c.next {
		layout_downwards_dependent(c, axis)
	}
	if box.pref_size[axis].kind == .Children_Sum {
		sum: f32 = 0
		for c := box.first; c != nil; c = c.next {
			if is_floating(c, axis) {
				continue
			}
			if axis == box.child_layout_axis {
				sum += c.fixed_size[axis]
			} else {
				sum = max(sum, c.fixed_size[axis])
			}
		}
		box.fixed_size[axis] = sum
	}
}

is_floating :: proc(b: ^Box, axis: Axis2) -> bool {
	if axis == .X {
		return .Floating_X in b.flags
	}
	return .Floating_Y in b.flags
}

// pass 4: solve violations. Along the layout axis, shrink children in
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

// pass 5: compute final rects. Children stack along the parent's layout axis;
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
	if s.modal_input_active && !box_in_modal_input_scope(box) {
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
	if .Drop_Site in box.flags && box.key != 0 && in_bounds && s.drop_hot == 0 {
		s.drop_hot = box.key
	}

	// Like RAD Debugger's UI_EventKind_Scroll path, the hovered box consumes
	// the admitted scroll row. Sibling widgets and the camera cannot replay it.
	sig.scroll = action_scroll_consume(s, false, r_min, r_max, true)
	// onimite: horizontal scrolling and Control-scroll zoom, consumed alike.
	sig.scroll_x = action_scroll_consume(s, false, r_min, r_max, true, horizontal = true)
	sig.zoom = action_scroll_consume(s, true, r_min, r_max, true)

	if .Clickable not_in box.flags {
		return sig
	}

	nav_root := default_nav_root_from_box(box)
	if nav_root != nil &&
	   nav_root.default_nav_focus_hot_key == Key(0) &&
	   .Focus_Nav_Skip not_in box.flags {
		nav_root.default_nav_focus_hot_key = box.key
	}

	// left press inside -> become hot + active, record drag origin
	if platform.mouse_pressed(s.p, .Left) && in_bounds {
		s.hot = box.key
		s.active = box.key
		s.drag_start = mp
		sig.flags |= {.Left_Pressed}
		if nav_root != nil && .Click_To_Focus in box.flags {
			nav_root.default_nav_focus_hot_key = box.key
			if nav_root.default_nav_focus_active_key != box.key {
				nav_root.default_nav_focus_active_key = Key(0)
			}
		}
	}
	if platform.mouse_pressed(s.p, .Right) && in_bounds {
		sig.flags |= {.Right_Pressed}
		s.right_active = box.key // onimite
	}
	if platform.mouse_pressed(s.p, .Middle) && in_bounds {
		sig.flags |= {.Middle_Pressed}
		s.middle_active = box.key // onimite
	}
	// onimite: middle and right drags last while their button is held.
	if s.middle_active == box.key {
		if platform.mouse_down(s.p, .Middle) || .Middle_Pressed in sig.flags {
			sig.flags |= {.Middle_Dragging}
		} else {
			s.middle_active = Key(0)
		}
	}
	if s.right_active == box.key {
		if platform.mouse_down(s.p, .Right) || .Right_Pressed in sig.flags {
			sig.flags |= {.Right_Dragging}
		} else {
			s.right_active = Key(0)
		}
	}

	// left release while active
	if platform.mouse_released(s.p, .Left) && s.active == box.key {
		sig.flags |= {.Left_Released}
		if in_bounds {
			sig.flags |= {.Left_Clicked}
		} else {
			s.hot = Key(0)
		}
		s.active = Key(0)
	}
	if platform.mouse_released(s.p, .Right) && in_bounds {
		sig.flags |= {.Right_Clicked}
	}
	if platform.mouse_released(s.p, .Middle) && in_bounds {
		sig.flags |= {.Middle_Clicked}
	}

	// active box (held) -> dragging
	if s.active == box.key || .Left_Pressed in sig.flags {
		if platform.mouse_down(s.p, .Left) || .Left_Pressed in sig.flags {
			sig.flags |= {.Left_Dragging}
		}
		sig.drag_delta = {mp.x - s.drag_start.x, mp.y - s.drag_start.y}
	}
	if sig.flags & {.Left_Dragging, .Middle_Dragging, .Right_Dragging} != {} {
		sig.drag_motion = platform.mouse_delta(s.p) // onimite
	}

	// hover: mouse over and no other box owns hot/active
	if in_bounds &&
	   (s.hot == Key(0) || s.hot == box.key) &&
	   (s.active == Key(0) || s.active == box.key) {
		s.hot = box.key
		sig.flags |= {.Hovering}
	}

	if default_nav_is_focus_hot(box) && action_pressed(s, .Accept) {
		sig.flags |= {.Keyboard_Pressed}
	}

	return sig
}
