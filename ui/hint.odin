package ui

import "../platform"
import "../render"
import "core:strings"

// Borrowed text for this build. Controls may supply catalog-derived help; UI
// only places and wraps it. No command knowledge is duplicated here.
hint :: proc(s: ^State, signal: Signal, text: string) {
	if hovering(signal) do s.hint = text
}
hint_draw :: proc(s: ^State) {
	if s.hint == "" || s.font == nil || s.r == nil do return
	// The same scale as other UI text; wrap at `width`, then fit the longest line.
	font_size := s.theme.default_font_px * s.font_scale * s.p.dpi_scale
	width := max(1, min(f32(620) * s.p.dpi_scale, f32(s.p.width) - 24))
	lines := make([dynamic]string, context.temp_allocator)
	remaining := s.hint
	for len(remaining) > 0 {
		end, last_space := 0, 0
		for i in 0 ..< len(remaining) {
			if remaining[i] == ' ' do last_space = i
			if remaining[i] == '\n' {end = i; break}
			end = i + 1
			if render.measure_text(s.font, remaining[:end], font_size) > width - 20 {
				end = last_space > 0 ? last_space : max(1, i)
				break
			}
		}
		append(&lines, remaining[:end])
		remaining = strings.trim_left(remaining[end:], " \n")
	}
	widest: f32
	for line in lines do widest = max(widest, render.measure_text(s.font, line, font_size))
	width = min(width, widest + 20)
	height := f32(len(lines)) * (font_size + 4) + 12
	mouse := platform.mouse_pos(s.p)
	x := clamp(mouse.x + 12, 0, max(0, f32(s.p.width) - width))
	y := clamp(mouse.y + 20, 0, max(0, f32(s.p.height) - height))
	render.draw_rect(s.r, x, y, width, height, {25, 30, 38, 250})
	for line, i in lines do render.draw_text(s.r, s.font, line, x + 10, y + 6 + f32(i) * (font_size + 4), font_size, {225, 230, 240, 255})
}
