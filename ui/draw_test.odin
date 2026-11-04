package ui

import "../animation"
import "../platform"
import "../render"
import vg "deps:ovg"
import "core:math"
import "core:testing"

// A pixel of a 100-pixel-wide software target.
@(private)
pixel_at :: proc(sw: ^vg.Software_Backend, x, y: int) -> [3]u8 {
	i := (y * 100 + x) * 4
	return {sw.pixels[i], sw.pixels[i + 1], sw.pixels[i + 2]}
}
@(private)
test_box :: proc(s: ^State, flags: Box_Flags, key: string, r: [4]f32, bg: [4]u8) -> ^Box {
	set_next_rect(s, r); set_next_bg_color(s, bg); set_next_corner_radius(s, 0)
	return build_box(s, flags, key)
}

// As RAD Debugger's: a parent's children draw last to first, so the child
// built first (which took the pointer first) lies on top; a parent's
// background is beneath its children, and its border, a pixel wide just
// outside its rect, over them.
@(test)
test_children_draw_last_to_first_border_after :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100}
	sw: vg.Software_Backend
	vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	s: State; init(&s, &c, &p, nil); defer destroy(&s)
	s.theme.background = {0, 0, 0, 255}
	build_begin(&s)
	parent := test_box(&s, {.Draw_Background, .Draw_Border}, "parent", {10, 10, 80, 80}, {200, 0, 0, 255})
	parent.border_color = {0, 0, 200, 255}
	push_parent(&s, parent)
	test_box(&s, {.Draw_Background}, "front", {20, 5, 40, 55}, {0, 200, 0, 255})
	test_box(&s, {.Draw_Background}, "back", {40, 40, 40, 40}, {200, 200, 0, 255})
	pop_parent(&s)
	build_end(&s)
	vg.flush(&c)
	testing.expect_value(t, pixel_at(&sw, 15, 50), [3]u8{200, 0, 0}) // the parent's background
	testing.expect_value(t, pixel_at(&sw, 50, 50), [3]u8{0, 200, 0}) // where both lie: the one built first
	testing.expect_value(t, pixel_at(&sw, 70, 70), [3]u8{200, 200, 0}) // the other
	testing.expect_value(t, pixel_at(&sw, 50, 9), [3]u8{0, 0, 200}) // the border, outside the rect, over the child crossing it
	testing.expect_value(t, pixel_at(&sw, 50, 7), [3]u8{0, 200, 0}) // the child past the border
	testing.expect_value(t, pixel_at(&sw, 15, 10), [3]u8{200, 0, 0}) // the rect's own edge is background
	testing.expect_value(t, pixel_at(&sw, 5, 5), [3]u8{0, 0, 0}) // the frame's background
}

// An icon fills the square centred in its box, keeping its aspect as RAD's
// icon glyphs do, however wide or tall the box.
@(test)
test_icons_keep_their_aspect :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100}
	sw: vg.Software_Backend
	vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	s: State; init(&s, &c, &p, nil); defer destroy(&s)
	s.theme.background = {0, 0, 0, 255}
	// A square ring, stroked along the 24 unit box's edges.
	ring := "M2 2 H22 V22 H2 Z"
	icons_set(&s, {ring})
	build_begin(&s)
	set_next_text_color(&s, {255, 255, 255, 255})
	wide := test_box(&s, {.Draw_Icon}, "wide", {0, 0, 100, 20}, {})
	wide.icon = ring
	set_next_text_color(&s, {255, 255, 255, 255})
	tall := test_box(&s, {.Draw_Icon}, "tall", {0, 30, 20, 70}, {})
	tall.icon = ring
	build_end(&s)
	vg.flush(&c)
	// Its square's left edge, 40 + 20 * 2 / 24 across, and none at the box's.
	testing.expect(t, pixel_at(&sw, 41, 10).r > 128)
	testing.expect_value(t, pixel_at(&sw, 2, 10), [3]u8{0, 0, 0})
	// Down a tall box: its square's top edge at 55 + 20 * 2 / 24, none at the box's top.
	testing.expect(t, pixel_at(&sw, 10, 56).r > 128)
	testing.expect_value(t, pixel_at(&sw, 10, 32), [3]u8{0, 0, 0})
}

// As RAD Debugger's: a Clip box scissors its children to its rect inset a
// pixel, and not its own background.
@(test)
test_clip_insets_children_a_pixel :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100}
	sw: vg.Software_Backend
	vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	s: State; init(&s, &c, &p, nil); defer destroy(&s)
	s.theme.background = {0, 0, 0, 255}
	build_begin(&s)
	clip := test_box(&s, {.Draw_Background, .Clip}, "clip", {10, 10, 80, 80}, {200, 0, 0, 255})
	push_parent(&s, clip)
	test_box(&s, {.Draw_Background}, "child", {0, 0, 100, 100}, {0, 200, 0, 255})
	pop_parent(&s)
	build_end(&s)
	vg.flush(&c)
	testing.expect_value(t, pixel_at(&sw, 10, 50), [3]u8{200, 0, 0}) // the rect's first pixel: clipped from the child
	testing.expect_value(t, pixel_at(&sw, 11, 50), [3]u8{0, 200, 0}) // inside the inset
	testing.expect_value(t, pixel_at(&sw, 88, 50), [3]u8{0, 200, 0})
	testing.expect_value(t, pixel_at(&sw, 89, 50), [3]u8{200, 0, 0}) // the rect's last pixel
	testing.expect_value(t, pixel_at(&sw, 5, 50), [3]u8{0, 0, 0}) // outside
}

// As RAD Debugger's dr_truncated_fancy_run_list: text wider than its box is
// cut where "..." still fits, and nothing is drawn past the box.
@(test)
test_text_too_wide_ends_in_an_ellipsis :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100}
	sw: vg.Software_Backend
	vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	font, ok := render.font_load(#load("../assets/fonts/JetBrainsMono-Regular.ttf")); assert(ok); defer render.font_unload(&font)
	s: State; init(&s, &c, &p, &font); defer destroy(&s)
	s.theme.background = {0, 0, 0, 255}
	ink :: proc(sw: ^vg.Software_Backend, x0, x1: int) -> bool {
		for y in 0 ..< 100 do for x in x0 ..< x1 do if pixel_at(sw, x, y) != {0, 0, 0} do return true
		return false
	}
	frame :: proc(s: ^State, c: ^vg.Canvas, flags: Box_Flags) {
		build_begin(s)
		set_next_font_size(s, 16); set_next_text_padding(s, 0); set_next_text_color(s, {255, 255, 255, 255})
		test_box(s, {.Draw_Text} + flags, "MMMMMMMMMMMMMMMMMMMM###label", {10, 40, 60, 20}, {0, 0, 0, 0})
		build_end(s)
		vg.flush(c)
	}
	frame(&s, &c, {})
	testing.expect(t, !ink(&sw, 70, 100), "nothing past the box")
	testing.expect(t, ink(&sw, 60, 70), "the ellipsis at the box's end")
	// Kept whole, it runs on past the box.
	frame(&s, &c, {.Disable_Text_Trunc})
	testing.expect(t, ink(&sw, 70, 100), "kept whole")
}

// The cut follows the text's order, as Pango, CoreText and Qt elide: a line
// read right to left keeps its start and puts its "..." at its end edge, the
// left, fading away from the text; a line mixing directions is laid out again
// so what it keeps lies together. The UI font has no Hebrew, so its letters
// draw as boxes reaching above the dots, which sit on the baseline. (onimite:
// set in ovg's Vera, whose "..." is three glyphs; its monospaced font has a
// ligature for it.)
@(test)
test_text_cut_follows_the_text_order :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100}
	sw: vg.Software_Backend
	vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	font, ok := render.font_load(vg.DEFAULT_FONT_DATA); assert(ok); defer render.font_unload(&font)
	s: State; init(&s, &c, &p, &font); defer destroy(&s)
	s.theme.background = {0, 0, 0, 255}
	frame :: proc(s: ^State, c: ^vg.Canvas, text: string) {
		build_begin(s)
		set_next_font_size(s, 16); set_next_text_padding(s, 0); set_next_text_color(s, {255, 255, 255, 255})
		box := test_box(s, {.Draw_Text}, "", {10, 40, 60, 20}, {0, 0, 0, 0})
		box.str = text
		build_end(s)
		vg.flush(c)
	}
	// The highest inked row in columns [x0, x1), and the brightest ink there.
	ink :: proc(sw: ^vg.Software_Backend, x0, x1: f32) -> (top: int, bright: u8) {
		top = 100
		for y in 0 ..< 100 do for x in int(x0) ..< int(x1) {
			v := pixel_at(sw, x, y).r
			if v > 0 do top = min(top, y)
			bright = max(bright, v)
		}
		return
	}
	// A dot's, a letter box's, M's and a space's advances.
	d, l := render.measure_text(&font, ".", 16), render.measure_text(&font, "א", 16)
	m, sp := render.measure_text(&font, "M", 16), render.measure_text(&font, " ", 16)
	frame(&s, &c, "....")
	dots, _ := ink(&sw, 10, 10 + d)
	frame(&s, &c, "MMMM")
	letters, _ := ink(&sw, 10, 10 + m)
	baseline := (dots + letters) / 2 // above it a box, below it only dots
	testing.expect(t, letters < dots, "letters reach above the dots")

	// Right to left: the dots on the left, the faintest first, the start of
	// the text after them and nothing past the box.
	frame(&s, &c, "אבגדהוזחטיכלמנסעפצקר")
	top, first := ink(&sw, 10, 10 + d)
	_, third := ink(&sw, 10 + 2 * d, 10 + 3 * d)
	testing.expect(t, top > baseline, "the trailer at the left")
	testing.expect(t, first < third, "the dot farthest from the text faintest")
	top, _ = ink(&sw, 10 + 3 * d + 1, 10 + 3 * d + l - 1)
	testing.expect(t, top < baseline, "the kept letters after the trailer")
	top, _ = ink(&sw, 71, 100)
	testing.expect_value(t, top, 100)

	// Mixed: "M " then Hebrew, cut inside the Hebrew word. Kept in place the
	// Hebrew left would lie at the word's far end, past the box; laid out
	// again it follows the space, and the dots follow it.
	frame(&s, &c, "M אבגדהוזחטיכלמנסע")
	kept := f32(int((60 - m - sp - 3 * d) / l)) // the Hebrew letters kept
	top, _ = ink(&sw, 10 + m + sp + 1, 10 + m + sp + l - 1)
	testing.expect(t, top < baseline, "the kept Hebrew after the space")
	top, _ = ink(&sw, 10 + m + sp + kept * l + 1, 10 + m + sp + kept * l + d)
	testing.expect(t, top > baseline, "the trailer after the kept text")
	top, _ = ink(&sw, 71, 100)
	testing.expect_value(t, top, 100)
}

// As RAD's: a clickable box focus hot lies under the focus overlay, one
// focus active inside the focus border, unless it disables them (a floating
// view's container, a search row); a scroll bar built in a list whose focus
// is On is outside it (RAD's UI_Focus(Null)): none of its parts lit.
@(test)
test_focus_overlay_and_border :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100}
	sw: vg.Software_Backend
	vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas
	vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	s: State; init(&s, &c, &p, nil); defer destroy(&s)
	s.theme.background = {0, 0, 0, 255}
	s.theme.focus_overlay, s.theme.focus_border = {0x22, 0x92, 0xeb, 0x14}, {0x23, 0x92, 0xeb, 0xff} // RAD's: the mechanism, whatever the palette
	frame :: proc(s: ^State, c: ^vg.Canvas, flags: Box_Flags) {
		build_begin(s)
		push_focus(s, .On)
		test_box(s, {.Clickable} + flags, "###focused", {10, 10, 40, 40}, {0, 0, 0, 0})
		pop_focus(s)
		build_end(s)
		vg.flush(c)
	}
	frame(&s, &c, {})
	// (placed, it floats: its border a pixel outside it)
	inside, edge := pixel_at(&sw, 30, 30), pixel_at(&sw, 9, 30)
	testing.expect(t, inside.b > 0 && inside.b < 40, "the overlay over it")
	testing.expect(t, edge.b > 200, "the border around it")
	frame(&s, &c, {.Disable_Focus_Overlay, .Disable_Focus_Border})
	testing.expect_value(t, pixel_at(&sw, 30, 30), [3]u8{0, 0, 0})
	testing.expect_value(t, pixel_at(&sw, 9, 30), [3]u8{0, 0, 0})

	// A list whose focus is On: its bar's parts are not focused.
	scroll: animation.Scroll
	build_begin(&s)
	push_focus(&s, .On)
	scroll_list_begin(&s, "###list", {100, 100}, &scroll, 50, 20)
	scroll_list_end(&s)
	pop_focus(&s)
	bar := s.scroll_list.content.next
	lit :: proc(b: ^Box) -> bool {
		if b.flags & {.Focus_Hot, .Focus_Active} != {} do return true
		for k := b.first; k != nil; k = k.next do if lit(k) do return true
		return false
	}
	testing.expect(t, !lit(bar))
	build_end(&s)
}

// A match's highlight spans the glyphs drawn (render.slot_cut, the cut the
// text is drawn with): on a line that fits, where its letters lie; on a line
// cut to "...", only where kept letters lie, none for letters cut away; on
// a line read right to left, its first letter at the kept text's right end,
// past the trailer on the left, inside the box (in ovg's Vera, as above).
@(test)
test_match_highlights_follow_the_drawn_text :: proc(t: ^testing.T) {
	font, ok := render.font_load(vg.DEFAULT_FONT_DATA); assert(ok); defer render.font_unload(&font)
	render.font_frame(&font)
	m, d, l := render.measure_text(&font, "M", 16), render.measure_text(&font, ".", 16), render.measure_text(&font, "א", 16)
	close :: proc(a, b: f32) -> bool {return abs(a - b) < 0.01}
	// Left to right, whole.
	text := "MMMM"
	cut := render.slot_cut(&font, render.text_slot(&font, text, 16), text, "...", 16, 60)
	x0, x1, hit := render.cut_span(&font, cut, text, 1, 2)
	testing.expect(t, hit && close(x0, m) && close(x1, 2 * m))
	// Cut: a kept letter where it lies, one cut away not at all.
	text = "MMMMMMMMMMMMMMMMMMMM"
	cut = render.slot_cut(&font, render.text_slot(&font, text, 16), text, "...", 16, 60)
	x0, x1, hit = render.cut_span(&font, cut, text, 1, 2)
	testing.expect(t, hit && close(x0, m) && close(x1, 2 * m))
	_, _, hit = render.cut_span(&font, cut, text, 19, 20)
	testing.expect(t, !hit)
	// Right to left, cut: the first letter (its first two bytes) the kept
	// text's rightmost, after the dots, inside the box; the last cut away.
	text = "אבגדהוזחטיכלמנסעפצקר"
	cut = render.slot_cut(&font, render.text_slot(&font, text, 16), text, "...", 16, 60)
	kept := f32(int((60 - 3 * d) / l))
	x0, x1, hit = render.cut_span(&font, cut, text, 0, 2)
	testing.expect(t, hit && close(x0, 3 * d + (kept - 1) * l) && close(x1, 3 * d + kept * l) && x1 <= 60)
	_, _, hit = render.cut_span(&font, cut, text, len(text) - 2, len(text))
	testing.expect(t, !hit)
}

// The scroll list after RAD Debugger's, laid out as RAD's: the rows beside a
// scroll bar, the rows' box fading at an edge while rows lie past it; the
// bar's arrow steps the list while held, and its thumb drags it from where
// the list was when it was pressed, over the area's free length.
@(test)
test_scroll_list_bar_steps_drags_and_fades :: proc(t: ^testing.T) {
	p := platform.Platform{width = 200, height = 200}
	p.frame_dt = 0.05 // the list eases toward where it is sent
	s: State; init(&s, nil, &p, nil); defer destroy(&s)
	defer delete(p.input.events)
	scroll: animation.Scroll
	jump: bool
	frame :: proc(s: ^State, scroll: ^animation.Scroll, jump: ^bool = nil) -> (target: f32, moved: bool, fades: Box_Flags) {
		test_gather(s)
		build_begin(s)
		scroll_list_begin(s, "###list", {100, 100}, scroll, 50, 20)
		fades = s.scroll_list.content.flags & {.Draw_Fade_Top, .Draw_Fade_Bottom}
		j: bool
		target, moved, j = scroll_list_end(s)
		if jump != nil do jump^ = j
		build_end(s)
		return
	}
	center :: proc(b: ^Box) -> [2]f32 {return (b.rect.min + b.rect.max) / 2}
	_, moved, fades := frame(&s, &scroll)
	testing.expect(t, !moved && fades == {.Draw_Fade_Bottom})
	testing.expect_value(t, scroll.maximum, f32(49)) // RAD's range: to the last row
	// The bar beside the rows, its width one and a half of the font.
	bar_w := scroll_bar_width(&s)
	testing.expect_value(t, s.scroll_list.content.fixed_size.x, 100 - bar_w)
	bar := s.scroll_list.content.next
	testing.expect_value(t, bar.rect.min.x, 100 - bar_w)
	// Held, the down arrow (the bar's foot) steps a row a frame.
	p.input.mouse = center(bar.last)
	frame(&s, &scroll)
	test_button(&p, .Left, true)
	target: f32
	target, moved, _ = frame(&s, &scroll, &jump)
	testing.expect(t, moved && target == 1 && !jump)
	animation.scroll_to(&scroll, target)
	target, moved, _ = frame(&s, &scroll)
	testing.expect(t, moved && target == 2)
	test_button(&p, .Left, false)
	frame(&s, &scroll)
	// Scrolled into the middle, both edges fade.
	animation.scroll_to(&scroll, 20)
	for _ in 0 ..< 60 do frame(&s, &scroll)
	_, _, fades = frame(&s, &scroll)
	testing.expect_value(t, fades, Box_Flags{.Draw_Fade_Top, .Draw_Fade_Bottom})
	// The thumb drags: its area's free length is the whole range (49 rows).
	area := bar.first.next
	thumb := area.first.next
	space := math.floor(box_size(area).y) - math.floor(box_size(thumb).y)
	p.input.mouse = center(thumb)
	frame(&s, &scroll)
	test_button(&p, .Left, true)
	frame(&s, &scroll)
	p.input.mouse.y += space * 5.5 / 49 // five and a half rows of the free length
	target, moved, _ = frame(&s, &scroll, &jump)
	// RAD's: a whole index, there at once (off = 0).
	testing.expect(t, moved && target == 25 && jump)
	test_button(&p, .Left, false)
	frame(&s, &scroll)
}

@(test)
test_hovered_row_keeps_background_alpha :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100, frame_dt = 1}
	sw: vg.Software_Backend; vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas; vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	s: State; init(&s, &c, &p, nil); defer destroy(&s)
	s.theme.background = {200, 100, 50, 255}
	s.theme.hover = {255, 255, 255, 255} // RAD's hover: the mechanism, whatever the palette

	draw :: proc(s: ^State, c: ^vg.Canvas, mouse: [2]f32) -> ^Box {
		s.p.input.mouse = mouse
		test_gather(s)
		build_begin(s)
		floating := test_box(s, {.Draw_Background}, "###floating", {10, 10, 80, 80}, s.theme.floating)
		push_parent(s, floating)
		set_next_fixed_x(s, 0); set_next_fixed_y(s, 10); set_next_fixed_width(s, 80); set_next_fixed_height(s, 20)
		sig := selection_row_begin(s, "###row", false, {0, 0, 0, 0})
		pop_parent(s)
		pop_parent(s)
		build_end(s)
		vg.flush(c)
		return sig.box
	}

	draw(&s, &c, {0, 0})
	unhovered_row := pixel_at(&sw, 50, 25)
	below_row := pixel_at(&sw, 50, 45)
	testing.expect_value(t, unhovered_row, below_row)

	row_box := draw(&s, &c, {50, 25})
	row_box = draw(&s, &c, {50, 25})
	testing.expect(t, row_box.hot_t > 0.99 && row_box.bg_color == {0, 0, 0, 0})
	hovered_row := pixel_at(&sw, 50, 25)
	below_hovered := pixel_at(&sw, 50, 45)
	// Clear row casts no drop shadow below itself, and brightens only by the 0.015 hover overlay.
	testing.expect_value(t, below_hovered, below_row)
	for ch in 0 ..< 3 {
		diff := int(hovered_row[ch]) - int(unhovered_row[ch])
		testing.expect(t, diff >= 2 && diff <= 5)
	}
}

@(test)
test_toggle_hover_and_shortcut_chip_isolation :: proc(t: ^testing.T) {
	p := platform.Platform{width = 100, height = 100, frame_dt = 1}
	sw: vg.Software_Backend; vg.software_backend_init(&sw); defer vg.software_backend_destroy(&sw)
	c: vg.Canvas; vg.canvas_init(&c, vg.software_backend(&sw)); defer vg.canvas_destroy(&c)
	s: State; init(&s, &c, &p, nil); defer destroy(&s)
	s.theme.background = {200, 100, 50, 255}
	s.theme.hover = {255, 255, 255, 255} // RAD's hover: the mechanism, whatever the palette
	toggled := false

	draw :: proc(s: ^State, c: ^vg.Canvas, toggled: ^bool, mouse: [2]f32) -> (toggle_box, chip_box: ^Box) {
		s.p.input.mouse = mouse
		test_gather(s)
		build_begin(s)
		floating := test_box(s, {.Draw_Background}, "###floating", {10, 10, 80, 80}, s.theme.floating)
		push_parent(s, floating)
		set_next_fixed_x(s, 0); set_next_fixed_y(s, 10); set_next_fixed_width(s, 80); set_next_fixed_height(s, 18)
		toggle_box = toggle_switch(s, toggled, "###snap", 18).box
		row := test_box(s, {.Clickable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, "###cmd_row", {0, 45, 80, 20}, {0, 0, 0, 0})
		push_parent(s, row)
		chip_box = test_box(s, {.Draw_Background, .Draw_Border, .Draw_Hot_Effects, .Draw_Active_Effects}, "###bind_btn", {50, 2, 24, 16}, s.theme.panel)
		pop_parent(s)
		pop_parent(s)
		build_end(s)
		vg.flush(c)
		return
	}

	draw(&s, &c, &toggled, {0, 0})
	unhovered_toggle := pixel_at(&sw, 65, 29)
	below_toggle := pixel_at(&sw, 25, 42)
	unhovered_chip := pixel_at(&sw, 72, 65)

	// Hovering the toggle brightens its container by RAD's 0.015 overlay and casts no shadow.
	toggle_box, _ := draw(&s, &c, &toggled, {25, 29})
	toggle_box, _ = draw(&s, &c, &toggled, {25, 29})
	testing.expect(t, toggle_box.hot_t > 0.99 && toggle_box.bg_color == {0, 0, 0, 0})
	hovered_toggle := pixel_at(&sw, 65, 29)
	below_hovered_toggle := pixel_at(&sw, 25, 42)
	testing.expect_value(t, below_hovered_toggle, below_toggle)
	for ch in 0 ..< 3 {
		diff := int(hovered_toggle[ch]) - int(unhovered_toggle[ch])
		testing.expect(t, diff >= 2 && diff <= 5)
	}

	// Hovering a command row does not light up its non-clickable shortcut chip.
	_, chip_box := draw(&s, &c, &toggled, {25, 65})
	_, chip_box = draw(&s, &c, &toggled, {25, 65})
	testing.expect_value(t, chip_box.hot_t, f32(0))
	testing.expect_value(t, pixel_at(&sw, 72, 65), unhovered_chip)
}
