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
//     frame, which is standard immediate-mode behaviour. As in RAD, a box
//     takes the events it is for as its signal is computed (a press by the
//     clickable box under it, a release by the box the press made active, a
//     wheel tick by the scrollable box under it), so what is built first takes
//     them first: a frame is built front to back, and drawn back to front
//     (each parent's children last to first, see draw.odin).
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
import "core:mem/virtual"
import "core:strings"

import platform "../platform"
import render "../render"
import vg "deps:ovg"

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
	Keyboard_Clickable, // focus hot, an accept press is its Keyboard_Pressed (RAD's KeyboardClickable)
	Scroll, // takes the wheel under the pointer (RAD's UI_BoxFlag_Scroll)
	Drop_Site, // first compatible site under the pointer owns the drop
	Click_To_Focus, // mouse press selects this box in its nearest nav root
	Default_Focus_Nav_X,
	Default_Focus_Nav_Y,
	Focus_Nav_Skip,
	// Built while focus is On (focus.odin): hot, active, and disabled where an
	// Off lies below (RAD's FocusHot, FocusActive and their Disabled flags).
	Focus_Hot,
	Focus_Active,
	Focus_Hot_Disabled,
	Focus_Active_Disabled,
	Draw_Background,
	Draw_Horizontal_Gradient,
	Draw_Border,
	Draw_Text,
	Draw_Icon, // its icon from the State's atlas, in its text colour
	Draw_Drop_Shadow, // a soft shadow beneath it, offset down and right (RAD's DrawDropShadow)
	Draw_Background_Blur, // what lies beneath it blurred, under its background (RAD's DrawBackgroundBlur)
	Draw_Fade_Top, // a shadow fading in at its top edge: more lies above (RAD's DrawFadeTop)
	Draw_Fade_Bottom,
	Draw_Hot_Effects, // brighten toward hot_t
	Draw_Active_Effects, // brighten toward active_t
	Clip, // its custom draw and children are scissored to its rect, inset a pixel (RAD's Clip)
	Disable_Text_Trunc, // its text is drawn whole, never cut to "..." (RAD's DisableTextTrunc)
	// Its fuzzy_ranges of its text are lit behind it (RAD's HasFuzzyMatchRanges).
	Has_Fuzzy_Match_Ranges,
	Floating_X, // fixed_pos.x is absolute (set automatically by fixed_x)
	Floating_Y,
	Fixed_Width, // fixed_size.x is authoritative (bypasses pref_size)
	Fixed_Height,
	// Its children keep their sizes past its own on that axis, laid out
	// from its view offset (RAD's AllowOverflowX/Y).
	Allow_Overflow_X,
	Allow_Overflow_Y,
	// Its view offset's target stays within what its children span (RAD's ViewClampX/Y).
	View_Clamp_X,
	View_Clamp_Y,
	// The wheel over it moves its view offset (RAD's ViewScrollX/Y): along
	// the one axis it scrolls, either axis of the wheel.
	View_Scroll_X,
	View_Scroll_Y,
	// Its subtree's boxes at its corners take its corners' radii (RAD's RoundChildrenByParent).
	Round_Children_By_Parent,
	// Its squish shrinks it toward its top-left corner, not its top's middle (RAD's SquishAnchored).
	Squish_Anchored,
	// Focus hot or active, it lights no focus overlay or no focus border
	// (RAD's DisableFocusOverlay, DisableFocusBorder): a floating view's
	// container, a search row.
	Disable_Focus_Overlay,
	Disable_Focus_Border,
}

Box_Flags :: bit_set[Box_Flag;u64]

Text_Align :: enum u8 {
	Left,
	Center,
	Right,
}

////////////////////////////////
// Box

// Box is one node in the per-frame tree. Keyed boxes come from State.box_arena
// and are reused across frames (found via State.box_table); transient boxes
// (Key 0) come from the arena of their build (State.build_arenas), as RAD's
// ui_build_box_from_key allocates them. Per-frame fields (links, sizes, rect
// target) are reset by build_box; persistent fields (hot_t, active_t, rect
// from last frame) survive.
Box :: struct {
	// intrusive tree (per-frame; nil-terminated)
	first, last, next, prev, parent: ^Box,
	child_count:                     int,

	// identity / config (rebuilt each frame)
	key:                             Key,
	flags:                           Box_Flags,
	str:                             string, // display string (arena-owned this frame)
	icon:                            string, // its icon's path data (Draw_Icon)
	hover_cursor:                    platform.Cursor, // the pointer's shape while it's hot or held (RAD's hover_cursor)
	// What the box draws itself with ovg, after its background, text and
	// icon and before its children, its clip in place: RAD Debugger's custom
	// draw (box_equip_custom_draw). Per frame.
	custom_draw:                     Custom_Draw,
	custom_data:                     rawptr,
	// The byte ranges of its text a filter matched, lit behind it
	// (box_equip_fuzzy_match_ranges). Per frame.
	fuzzy_ranges:                    [][2]int,
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
	// Per corner, as RAD's: 00 top-left, 01 bottom-left, 10 top-right, 11 bottom-right.
	corner_radii:                    [4]f32,
	squish:                          f32, // drawn scaled by 1 - squish about its pivot (RAD's squish)
	// Its background, border and icon drawn this far inside its rect on
	// each side, its rect still what takes the pointer (RAD's visual_margin).
	visual_margin:                   [2]f32,
	blur_size:                       f32, // how far a background blur spreads (RAD's blur_size)
	font_size:                       f32,
	text_padding:                    f32,
	text_width:                      f32,
	text_height:                     f32,
	text_slot:                       int, // its text laid out this frame (render.text_slot), once measured
	text_metrics_valid:              bool,
	opacity:                         f32,

	// computed layout (rect.min/max in pixels)
	rect:                            struct {
		min, max: [2]f32,
	},

	// persistent state (survives across frames)
	hot_t, active_t:                 f32,
	// How far its children are scrolled, easing toward its target, and what
	// they span (RAD's view_off, view_off_target, view_bounds).
	view_off, view_off_target:       [2]f32,
	view_bounds:                     [2]f32,
	focus_hot_t, focus_active_t:     f32,
	first_build_index:               u64,
	last_build_index:                u64,
	default_nav_focus_hot_key:       Key,
	default_nav_focus_active_key:    Key,
	// Set during a frame, taken as the next begins (RAD's next keys).
	default_nav_focus_next_hot_key:    Key,
	default_nav_focus_next_active_key: Key,
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
	// Its button held since it pressed on this box (RAD's
	// LeftDragging, MiddleDragging, RightDragging).
	Left_Dragging,
	Middle_Dragging,
	Right_Dragging,
	Right_Pressed,
	Right_Clicked,
	Middle_Pressed,
	Middle_Clicked,
	Hovering, // this box owns the hot key this frame
	Mouse_Over, // mouse is within rect (possibly occluded)
	Keyboard_Pressed,
	// Its press doubles (triples) its last press(es) within DOUBLE_CLICK_SECONDS,
	// as RAD's press history gives them.
	Left_Double_Clicked,
	Middle_Double_Clicked,
	Right_Double_Clicked,
	Left_Triple_Clicked,
	Middle_Triple_Clicked,
	Right_Triple_Clicked,
}
DOUBLE_CLICK_SECONDS :: 0.4

Sig_Flags :: bit_set[Sig_Flag;u32]

// Signal is the interaction result for a box, computed against the box's
// last-frame rect. `drag_delta` is mouse-now minus press-origin. `scroll` is
// the wheel it took in RAD's steps (scroll_steps: three a notch), down and
// right positive; with Shift held the axes swap (RAD's sig.scroll).
Signal :: struct {
	box:        ^Box,
	flags:      Sig_Flags,
	drag_delta: [2]f32,
	scroll:     [2]f32,
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
middle_dragging :: proc(s: Signal) -> bool {return .Middle_Dragging in s.flags}
right_dragging :: proc(s: Signal) -> bool {return .Right_Dragging in s.flags}
double_clicked :: proc(s: Signal) -> bool {return .Left_Double_Clicked in s.flags}
keyboard_pressed :: proc(s: Signal) -> bool {return .Keyboard_Pressed in s.flags}
right_clicked :: proc(s: Signal) -> bool {return .Right_Clicked in s.flags}
middle_clicked :: proc(s: Signal) -> bool {return .Middle_Clicked in s.flags}

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
	canvas:             ^vg.Canvas, // what the frame is drawn on (draw.odin)
	// Where the frame is drawn (the app's frame image; nil, the screen) and
	// its layers, which a backdrop blur reads (ovg's layer_backdrop_blur).
	target:             vg.Render_Target,
	layers:             vg.Layer_Stack,
	path:               vg.Path, // scratch for what draw builds
	p:                  ^platform.Platform,
	font:               ^render.Font,

	// Keyed boxes, from box_arena and reused through the free list once
	// pruned (RAD's ui_state->arena and first_free_box).
	box_table:          map[Key]^Box,
	box_arena:          virtual.Arena,
	first_free_box:     ^Box,
	// Transient boxes (Key 0), in the arena of their build: two, alternating
	// by build_index, so the last build's stay valid through this one (RAD's
	// build_arenas).
	build_arenas:       [2]virtual.Arena,

	// build state
	root:               ^Box,
	build_index:        u64,
	build_box_count:    int,

	// interaction
	hot:                Key,
	hint:               string,
	drop_hot:           Key,
	active:             [platform.Mouse_Button]Key, // per button, the box its press made active
	// Per button, the boxes its last presses went to and when, newest first
	// (RAD's press_key_history and press_timestamp_history_us).
	press_keys:         [platform.Mouse_Button][3]Key,
	press_times:        [platform.Mouse_Button][3]f64,
	// Where the last press began, and what its owner kept of the state the
	// drag started from (RAD's drag_start_mouse and drag state data:
	// store_drag_struct, drag_struct).
	drag_start:         [2]f32,
	drag_data:          [dynamic]u8,
	actions:            Action_Storage,
	animations:         Animation_Storage,
	is_animating:       bool,
	font_scale:         f32, // every box's font size times this (the app's window font size)
	default_nav_root:   Key,
	// Text was being edited this frame, as RAD's text_edit_mode: a key that
	// types a character then types it (view/keys.odin). Multi-line: Enter
	// too.
	text_edit_mode, text_edit_mode_multiline: bool,

	// parent stack (explicit; not folded into the generic stacks)
	parent_stack:       [dynamic]^Box,
	// The root's first child, so it draws over everything: what a tooltip
	// (tooltip_begin) builds goes in it, as RAD's tooltip root.
	tooltip_root:       ^Box,
	icons:              map[string]vg.Shape, // what Draw_Icon boxes fill: each icon's stroke, made once (icons_set)
	scroll_list:        Scroll_List, // the list begun and not yet ended (scroll.odin)

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
	squish:             Stack(f32),
	visual_margin:      Stack([2]f32),
	blur_size:          Stack(f32),
	font_size:          Stack(f32),
	text_padding:       Stack(f32),
	opacity:            Stack(f32),
	icon:               Stack(string),
	hover_cursor:       Stack(platform.Cursor),
	focus_hot:          Stack(Focus_Kind),
	focus_active:       Stack(Focus_Kind),

	// theme defaults
	theme:              Theme,
}

// Theme holds default colors + metrics. Kept simple and public so callers can
// tweak it after `init`.
Theme :: struct {
	background:       [4]u8,
	panel:            [4]u8,
	text:             [4]u8,
	border:           [4]u8,
	active:           [4]u8,
	hover:            [4]u8, // hover overlay and border brighten, as RAD's "hover"
	accent:           [4]u8,
	selection:        [4]u8, // selected text behind it, as RAD's "selection"
	drop_shadow:      [4]u8, // shadows and edge fades, as RAD's drop_shadow
	inactive:         [4]u8, // over what a floating view leaves beneath it, as RAD's "inactive background"
	floating:         [4]u8, // a floating view's background: translucent, over its blur (RAD's "floating background")
	floating_border:  [4]u8,
	focus_overlay:    [4]u8, // over a clickable box focus hot, as RAD's "focus overlay"
	focus_border:     [4]u8, // around a clickable box focus active, as RAD's "focus border"
	match:            [4]u8, // behind a filter's matched letters, as RAD's "match background"
	blur_size:        f32, // RAD's window blur size
	default_font_px:  f32,
	default_padding:  f32,
	default_corner:   f32,
	// How often a second hot_t, active_t and a box's view offset halve their
	// distance to their targets (RAD's catchall and scrolling rates, 60).
	hot_anim_rate:    f32,
	active_anim_rate: f32,
	scroll_anim_rate: f32,
}

default_theme :: proc() -> Theme {
	return Theme {
		background = {24, 26, 32, 255},
		panel = {38, 42, 52, 255},
		text = {224, 228, 236, 255},
		border = {70, 78, 92, 255},
		// onimite's own palette (v0.0.78's) in RAD's slots: its hot colour
		// tints the hover, its lister the floating views (opaque, its
		// border and backdrop), its accent the focus (an overlay that over
		// the lister lands on its selected row's colour) and the selection.
		active = {90, 130, 200, 255},
		hover = {60, 68, 84, 255},
		accent = {96, 150, 230, 255},
		selection = {96, 150, 230, 90},
		drop_shadow = {0, 0, 0, 150},
		inactive = {0, 0, 0, 150},
		floating = {28, 31, 38, 255},
		floating_border = {92, 100, 116, 255},
		focus_overlay = {96, 150, 230, 87},
		focus_border = {96, 150, 230, 255},
		match = {60, 68, 84, 255},
		blur_size = 10,
		default_font_px = 18,
		default_padding = 6,
		default_corner = 4,
		hot_anim_rate = 60,
		active_anim_rate = 60,
		scroll_anim_rate = 60,
	}
}

// What each box arena reserves (committed as it is used): RAD's default
// arena reserve (base/base_arena.h).
ARENA_RESERVE :: 64 * 1024 * 1024

// init wires a State to the renderer/platform/font and seeds the theme.
init :: proc(s: ^State, canvas: ^vg.Canvas, p: ^platform.Platform, font: ^render.Font) {
	s.canvas = canvas
	s.p = p
	s.font = font
	s.box_table = make(map[Key]^Box)
	_ = virtual.arena_init_growing(&s.box_arena, ARENA_RESERVE)
	for &a in s.build_arenas do _ = virtual.arena_init_growing(&a, ARENA_RESERVE)
	s.parent_stack = make([dynamic]^Box)
	s.actions = action_storage_make()
	s.animations = animation_storage_make()
	s.theme = default_theme()
	s.font_scale = 1
	s.build_index = 0
}

// destroy frees all persistent boxes and the State's containers.
destroy :: proc(s: ^State) {
	delete(s.box_table)
	virtual.arena_destroy(&s.box_arena)
	for &a in s.build_arenas do virtual.arena_destroy(&a)
	delete(s.parent_stack)
	delete(s.drag_data)
	if s.canvas != nil do vg.layer_stack_destroy(&s.layers, s.canvas)
	vg.path_destroy(&s.path)
	for _, &icon in s.icons do vg.shape_destroy(&icon)
	delete(s.icons)
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
	delete(s.squish.items)
	delete(s.visual_margin.items)
	delete(s.blur_size.items)
	delete(s.font_size.items)
	delete(s.text_padding.items)
	delete(s.opacity.items)
	delete(s.icon.items)
	delete(s.hover_cursor.items)
	delete(s.focus_hot.items)
	delete(s.focus_active.items)
}

////////////////////////////////
// Build phase

// build_begin starts a frame: bumps build_index, clears its build arena (what
// the build before last allocated), clears stacks, and pushes a
// framebuffer-sized root box. Interaction keys computed last frame carry over.
build_begin :: proc(s: ^State) {
	s.build_index += 1
	s.build_box_count = 0
	if s.font != nil && s.font.text != nil do render.font_frame(s.font)
	s.is_animating = false
	s.hint = ""
	animation_storage_prune(&s.animations, s.build_index)
	// The frame's input rows are made before the build, as RAD's events
	// are before ui_begin_build: one a window event, in order (the app's
	// key_route, through action_push_event for the pointer's).
	default_nav_process(s)
	s.default_nav_root = Key(0)
	// What the navigation roots focused last frame takes effect now (RAD's
	// next-default-nav-focus keys).
	for _, b in s.box_table {
		b.default_nav_focus_hot_key = b.default_nav_focus_next_hot_key
		b.default_nav_focus_active_key = b.default_nav_focus_next_active_key
	}

	virtual.arena_free_all(&s.build_arenas[s.build_index % len(s.build_arenas)])

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
	stack_reset(&s.squish)
	stack_reset(&s.visual_margin)
	stack_reset(&s.blur_size)
	stack_reset(&s.font_size)
	stack_reset(&s.text_padding)
	stack_reset(&s.opacity)
	stack_reset(&s.icon)
	stack_reset(&s.hover_cursor)
	stack_reset(&s.focus_hot)
	stack_reset(&s.focus_active)

	// As RAD's ui_begin_build: hot is re-derived from the pointer as signals
	// are computed, unless a box holds a button; drop-hot always is.
	if s.active == {} {
		s.hot = Key(0)
	}
	s.drop_hot = 0
	// A box a button made active that is gone (pruned) holds nothing.
	for &active in s.active {
		if active != Key(0) && active not_in s.box_table do active = Key(0)
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
	// The tooltip root, the root's first child: it draws over everything.
	set_next_fixed_x(s, 0); set_next_fixed_y(s, 0)
	set_next_fixed_width(s, fbw); set_next_fixed_height(s, fbh)
	s.tooltip_root = build_box(s, {}, "###ui_tooltips")
}
// Build into the tooltip root, over everything else, until tooltip_end.
tooltip_begin :: proc(s: ^State) {push_parent(s, s.tooltip_root)}
tooltip_end :: proc(s: ^State) {pop_parent(s)}

stack_reset :: proc(s: ^Stack($T)) {
	clear(&s.items)
	s.next = nil
}

// build_end, as RAD's ui_end_build: prunes any keyed box not touched this
// frame, runs the 5-pass layout (X then Y), rounds children, animates the
// keyed boxes, then draws the tree.
build_end :: proc(s: ^State) {
	pop_parent(s) // pop root
	prune(s)

	// 5-pass autolayout, per axis.
	for axis in Axis2 {
		layout_standalone(s, s.root, axis)
		layout_upwards_dependent(s.root, axis)
		layout_downwards_dependent(s.root, axis)
		layout_enforce_constraints(s.root, axis)
		layout_position(s.root, axis)
	}
	children_round(s)
	view_animate(s, s.p.frame_dt)

	// The pointer's shape, as RAD's ui_end_build: the box the left button
	// holds, else the hot one, sets it, while the window has the focus or a
	// box is held.
	held := box_from_key(s, s.active[.Left])
	under := held if held != nil else box_from_key(s, s.hot)
	if s.p.input.focused || held != nil do platform.set_cursor(s.p, under.hover_cursor if under != nil else .Pointer)

	// draw + animate
	draw(s)
	animations_advance(s)
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
			// A key built twice in one frame: the second is transient.
			if existing.last_build_index == s.build_index {
				transient = true
				key = Key(0)
			} else {
				box = existing
			}
		}
	}

	first_frame := false
	if box == nil {
		first_frame = true
		if transient {
			box = new(Box, virtual.arena_allocator(&s.build_arenas[s.build_index % len(s.build_arenas)]))
		} else {
			box = s.first_free_box
			if box != nil {
				s.first_free_box = box.next
				box^ = {}
			} else {
				box = new(Box, virtual.arena_allocator(&s.box_arena))
			}
			box.first_build_index = s.build_index
			s.box_table[key] = box
		}
	}

	// reset per-frame fields (preserve persistent hot_t/active_t/rect)
	box.first = nil
	box.last = nil
	box.next = nil
	box.prev = nil
	box.parent = nil
	box.child_count = 0
	box.key = key
	box.text_metrics_valid = false
	box.custom_draw, box.custom_data = nil, nil // equipped again each frame it draws itself
	box.fuzzy_ranges = nil

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
	focus_flags(s, box)

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
	box.icon = stack_use(&s.icon, "")
	box.hover_cursor = stack_use(&s.hover_cursor, platform.Cursor.Pointer)
	box.text_padding = stack_use(&s.text_padding, s.theme.default_padding)
	box.opacity = stack_use(&s.opacity, 1)
	r := stack_use(&s.corner_radius, s.theme.default_corner)
	box.corner_radii = {r, r, r, r}
	box.squish = stack_use(&s.squish, 0)
	box.visual_margin = stack_use(&s.visual_margin, [2]f32{})
	box.blur_size = stack_use(&s.blur_size, s.theme.blur_size)
	box.bg_color = stack_use(&s.bg_color, s.theme.panel)
	box.gradient_left = box.bg_color
	box.gradient_right = box.bg_color
	box.text_color = stack_use(&s.text_color, s.theme.text)
	box.border_color = stack_use(&s.border_color, s.theme.border)
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
		b.next = s.first_free_box
		s.first_free_box = b
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

// Where a box's text starts, its baseline's left end, as RAD's
// ui_box_text_position: centred or right-aligned text never starts left of
// the box, so what doesn't fit is cut at the right.
box_text_position :: proc(s: ^State, box: ^Box) -> [2]f32 {
	box_text_metrics_ensure(s, box)
	ascent := render.ascent(s.font, box.font_size)
	descent := box.font_size - ascent
	p: [2]f32
	p.y = math.floor((box.rect.min.y + box.rect.max.y) / 2 + ascent / 2 - descent / 2)
	switch box.text_align {
	case .Left:
		p.x = box.rect.min.x + box.text_padding
	case .Center:
		p.x = max(math.round((box.rect.min.x + box.rect.max.x) / 2 - box.text_width / 2), box.rect.min.x)
	case .Right:
		p.x = max(math.round(box.rect.max.x - box.text_width - box.text_padding), box.rect.min.x)
	}
	p.x = math.floor(p.x)
	return p
}

// The box after `box` in a pre-order walk of `root`'s tree, nil when it is
// done, and how many levels it climbs to reach it: RAD's ui_box_rec_df_pre
// (ui_core.c:338-358). The layout passes walk the tree with it, not by
// recursion.
Box_Rec :: struct {
	next:      ^Box,
	pop_count: int,
}
box_rec_df_pre :: proc(box, root: ^Box) -> (r: Box_Rec) {
	if box.first != nil do return {next = box.first}
	for p := box; p != nil && p != root; p = p.parent {
		if p.next != nil {r.next = p.next; return}
		r.pop_count += 1
	}
	return
}

// pass 1: standalone sizes (pixels, text content). Fixed_* already set size.
layout_standalone :: proc(s: ^State, root: ^Box, axis: Axis2) {
	for box := root; box != nil; box = box_rec_df_pre(box, root).next {
		if axis == .X && .Fixed_Width in box.flags do continue
		if axis == .Y && .Fixed_Height in box.flags do continue
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
}

// pass 2: upwards-dependent (parent pct of nearest fixed-size ancestor).
layout_upwards_dependent :: proc(root: ^Box, axis: Axis2) {
	for box := root; box != nil; box = box_rec_df_pre(box, root).next {
		if box.pref_size[axis].kind != .Parent_Pct do continue
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
}

// pass 3: downwards-dependent (children sum / max). Each box and the
// ancestors whose subtrees it ends are summed as the walk leaves them, so
// children are sized before parents, as RAD's pass.
layout_downwards_dependent :: proc(root: ^Box, axis: Axis2) {
	for box := root; box != nil; {
		rec := box_rec_df_pre(box, root)
		b := box
		for _ in 0 ..= rec.pop_count {
			if b == nil do break
			if b.pref_size[axis].kind == .Children_Sum {
				sum: f32 = 0
				for c := b.first; c != nil; c = c.next {
					if is_floating(c, axis) {
						continue
					}
					if axis == b.child_layout_axis {
						sum += c.fixed_size[axis]
					} else {
						sum = max(sum, c.fixed_size[axis])
					}
				}
				b.fixed_size[axis] = sum
			}
			b = b.parent
		}
		box = rec.next
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
// A box that allows overflow on the axis keeps its children's sizes, and its
// fraction-sized children take their fraction of it again (RAD's
// ui_layout_enforce_constraints).
layout_enforce_constraints :: proc(root: ^Box, axis: Axis2) {
	for box := root; box != nil; box = box_rec_df_pre(box, root).next {
		overflow := .Allow_Overflow_X in box.flags if axis == .X else .Allow_Overflow_Y in box.flags
		// off-axis: clamp each child to the parent's size
		if axis != box.child_layout_axis && !overflow {
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
		if axis == box.child_layout_axis && !overflow {
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

		if overflow {
			for c := box.first; c != nil; c = c.next {
				if c.pref_size[axis].kind == .Parent_Pct do c.fixed_size[axis] = box.fixed_size[axis] * c.pref_size[axis].value
			}
		}

		// enforce min sizes
		for c := box.first; c != nil; c = c.next {
			c.fixed_size[axis] = max(c.fixed_size[axis], c.min_size[axis])
		}
	}
}

// pass 5: compute final rects. Children stack along the parent's layout axis,
// less the parent's view offset; floating children use their fixed_pos. What
// the laid-out children span is the parent's view bounds (RAD's
// ui_layout_position).
layout_position :: proc(root: ^Box, axis: Axis2) {
	for box := root; box != nil; box = box_rec_df_pre(box, root).next {
		layout_pos: f32 = 0
		bounds: f32 = 0
		for c := box.first; c != nil; c = c.next {
			if !is_floating(c, axis) {
				c.fixed_pos[axis] = layout_pos
				if box.child_layout_axis == axis {
					layout_pos += c.fixed_size[axis]
					bounds += c.fixed_size[axis]
				} else {
					bounds = max(bounds, c.fixed_size[axis])
				}
			}
			c.rect.min[axis] = box.rect.min[axis] + c.fixed_pos[axis] - math.floor(box.view_off[axis])
			c.rect.max[axis] = c.rect.min[axis] + c.fixed_size[axis]
			// floor to whole pixels (raddbg does this to avoid text shimmer)
			c.rect.min[axis] = math.floor(c.rect.min[axis])
			c.rect.max[axis] = math.floor(c.rect.max[axis])
		}
		box.view_bounds[axis] = bounds
	}
}

// As RAD's ui_end_build child rounding (ui_core.c:1305-1345): in a keyed box
// that rounds its children, each box of its subtree at one of its corners
// takes that corner's radius, and its first child takes its top corners and
// its last child its bottom ones.
children_round :: proc(s: ^State) {
	f :: math.floor
	for _, box in s.box_table {
		if .Round_Children_By_Parent not_in box.flags do continue
		lo, hi := box.rect.min, box.rect.max
		for b := box; b != nil; b = box_rec_df_pre(b, box).next {
			if f(b.rect.min.x) <= f(lo.x) && f(b.rect.min.y) <= f(lo.y) do b.corner_radii[0] = box.corner_radii[0]
			if f(b.rect.max.x) >= f(hi.x) && f(b.rect.min.y) <= f(lo.y) do b.corner_radii[2] = box.corner_radii[2]
			if f(b.rect.min.x) <= f(lo.x) && f(b.rect.max.y) >= f(hi.y) do b.corner_radii[1] = box.corner_radii[1]
			if f(b.rect.max.x) >= f(hi.x) && f(b.rect.max.y) >= f(hi.y) do b.corner_radii[3] = box.corner_radii[3]
		}
		if box.first != nil do box.first.corner_radii[0], box.first.corner_radii[2] = box.corner_radii[0], box.corner_radii[2]
		if box.last != nil do box.last.corner_radii[1], box.last.corner_radii[3] = box.corner_radii[1], box.corner_radii[3]
	}
}
// As RAD's ui_end_build animation over its keyed boxes (ui_core.c:1385-1478):
// focus at once (its focus rate is 1), and a view-clamped box's target stays
// within its view bounds, its view offset easing toward the target and
// landing on it within two pixels.
view_animate :: proc(s: ^State, dt: f32) {
	for _, box in s.box_table {
		box.focus_hot_t = .Focus_Hot in box.flags && .Focus_Hot_Disabled not_in box.flags ? 1 : 0
		box.focus_active_t = .Focus_Active in box.flags && .Focus_Active_Disabled not_in box.flags ? 1 : 0
		limit := [2]f32{max(0, box.view_bounds.x - box.fixed_size.x), max(0, box.view_bounds.y - box.fixed_size.y)}
		if .View_Clamp_X in box.flags do box.view_off_target.x = clamp(box.view_off_target.x, 0, limit.x)
		if .View_Clamp_Y in box.flags do box.view_off_target.y = clamp(box.view_off_target.y, 0, limit.y)
		for axis in 0 ..< 2 {
			if abs(box.view_off_target[axis] - box.view_off[axis]) > 0.5 do s.is_animating = true
			box.view_off[axis] = animation.approach(box.view_off[axis], box.view_off_target[axis], s.theme.scroll_anim_rate * math.LN2, dt)
			if abs(box.view_off[axis] - box.view_off_target[axis]) < 2 do box.view_off[axis] = box.view_off_target[axis]
		}
	}
}

////////////////////////////////
// Signal computation
//
// Faithful to raddbg ui_signal_from_box: interaction is resolved against the
// box's rect FROM LAST FRAME (this frame's rect is not yet final when widgets
// query signals). Mouse position + edge-detected buttons come from platform.

// The pointer's motion since the last press began (RAD's ui_drag_delta).
drag_delta :: proc(s: ^State) -> [2]f32 {return platform.mouse_pos(s.p) - s.drag_start}
// What a drag's owner keeps of the state it started from, as its press
// stores it and its drag reads it back (RAD's ui_store_drag_struct and
// ui_get_drag_struct): one value at a time, the last press's.
store_drag_struct :: proc(s: ^State, v: ^$T) {
	clear(&s.drag_data)
	append(&s.drag_data, ..(transmute([^]u8)v)[:size_of(T)])
}
drag_struct :: proc(s: ^State, $T: typeid) -> ^T {
	if len(s.drag_data) < size_of(T) do resize(&s.drag_data, size_of(T))
	return (^T)(raw_data(s.drag_data))
}
// No box holds a button any more (RAD's ui_kill_action): a drag cancelled.
kill_action :: proc(s: ^State) {s.active = {}}

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
	contains :: proc(lo, hi, p: [2]f32) -> bool {return p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y}

	// The events this box is for, each taken here so no box asking later
	// sees it (RAD's ui_signal_from_box): a press by the clickable box under
	// it, a release by the box its press made active, a wheel tick by the
	// scrollable box under it.
	pressed_flag := [platform.Mouse_Button]Sig_Flag{.Left = .Left_Pressed, .Middle = .Middle_Pressed, .Right = .Right_Pressed}
	clicked_flag := [platform.Mouse_Button]Sig_Flag{.Left = .Left_Clicked, .Middle = .Middle_Clicked, .Right = .Right_Clicked}
	double_flag := [platform.Mouse_Button]Sig_Flag{.Left = .Left_Double_Clicked, .Middle = .Middle_Double_Clicked, .Right = .Right_Double_Clicked}
	triple_flag := [platform.Mouse_Button]Sig_Flag{.Left = .Left_Triple_Clicked, .Middle = .Middle_Triple_Clicked, .Right = .Right_Triple_Clicked}
	for &action in s.actions.rows {
		if action.consumed do continue
		in_bounds := contains(r_min, r_max, action.position)
		#partial switch action.kind {
		case .Mouse_Press:
			if .Clickable not_in box.flags || !in_bounds do continue
			s.hot = box.key
			s.active[action.button] = box.key
			sig.flags |= {pressed_flag[action.button]}
			if box.key != 0 {
				now := platform.time(s.p)
				keys, times := &s.press_keys[action.button], &s.press_times[action.button]
				if box.key == keys[0] && now - times[0] <= DOUBLE_CLICK_SECONDS do sig.flags |= {double_flag[action.button]}
				if box.key == keys[0] && box.key == keys[1] && now - times[0] <= DOUBLE_CLICK_SECONDS && times[0] - times[1] <= DOUBLE_CLICK_SECONDS do sig.flags |= {triple_flag[action.button]}
				keys[2], keys[1], keys[0] = keys[1], keys[0], box.key
				times[2], times[1], times[0] = times[1], times[0], now
			}
			s.drag_start = action.position
			if action.button == .Left {
				// As RAD's: pressing a box in a navigation root focuses it there
				// from the next frame.
				nav_root := default_nav_root_from_box(box)
				if nav_root != nil && .Click_To_Focus in box.flags {
					nav_root.default_nav_focus_next_hot_key = box.key
					if nav_root.default_nav_focus_active_key != box.key do nav_root.default_nav_focus_next_active_key = Key(0)
				}
			}
			action.consumed = true
		case .Mouse_Release:
			if .Clickable not_in box.flags || box.key == 0 || s.active[action.button] != box.key do continue
			s.active[action.button] = Key(0)
			if action.button == .Left do sig.flags |= {.Left_Released}
			if in_bounds {sig.flags |= {clicked_flag[action.button]}} else {s.hot = Key(0)}
			action.consumed = true
		case .Scroll:
			// As RAD's: with no modifier or Shift alone, Shift swapping the
			// axes. A Scroll box takes each event's steps (scroll_steps: a
			// notch three); a view-scrolled one moves its view offset by the
			// wheel's pixels (120 a notch), a lone axis taking either of the
			// wheel's (RAD's view scrolling).
			// (a view-scrolled box built before this frame: RAD's first-build
			// guard)
			view := box.flags & {.View_Scroll_X, .View_Scroll_Y} != {} && box.first_build_index != box.last_build_index
			if .Scroll not_in box.flags && !view || action.modifiers - {.Shift} != {} || !in_bounds do continue
			delta := action.scroll_delta
			if .Shift in action.modifiers do delta = delta.yx
			if .Scroll in box.flags do sig.scroll += scroll_steps(delta)
			if view {
				if .View_Scroll_X not_in box.flags {
					if delta.y == 0 do delta.y = delta.x
					delta.x = 0
				}
				if .View_Scroll_Y not_in box.flags {
					if delta.x == 0 do delta.x = delta.y
					delta.y = 0
				}
				box.view_off_target += delta
			}
			action.consumed = true
		}
	}

	mp := platform.mouse_pos(s.p)
	in_bounds := contains(r_min, r_max, mp)
	if in_bounds {
		sig.flags |= {.Mouse_Over}
	}
	// The first drop site under the pointer is drop-hot; leaving it, none is.
	if .Drop_Site in box.flags && box.key != 0 {
		if in_bounds && (s.drop_hot == 0 || s.drop_hot == box.key) {s.drop_hot = box.key} else if !in_bounds && s.drop_hot == box.key {s.drop_hot = 0}
	}

	if .Clickable not_in box.flags {
		return sig
	}

	// active box (held) -> dragging, per button (RAD's LeftDragging<<k)
	dragging_flag := [platform.Mouse_Button]Sig_Flag{.Left = .Left_Dragging, .Middle = .Middle_Dragging, .Right = .Right_Dragging}
	for button in platform.Mouse_Button {
		if box.key != 0 && s.active[button] == box.key || pressed_flag[button] in sig.flags do sig.flags |= {dragging_flag[button]}
	}
	if .Left_Dragging in sig.flags do sig.drag_delta = drag_delta(s)

	// hover: the first clickable box under the pointer, while no other box
	// is hot or holds a button
	if in_bounds && (s.hot == Key(0) || s.hot == box.key) {
		held := false
		for active in s.active do held ||= active != Key(0) && active != box.key
		if !held {
			s.hot = box.key
			sig.flags |= {.Hovering}
		}
	}

	// Focus hot and keyboard clickable, an accept press is its keyboard press
	// (RAD's ui_signal_from_box).
	if .Keyboard_Clickable in box.flags && .Focus_Hot in box.flags && .Focus_Hot_Disabled not_in box.flags && action_pressed(s, .Accept) {
		sig.flags |= {.Keyboard_Pressed}
	}

	return sig
}
