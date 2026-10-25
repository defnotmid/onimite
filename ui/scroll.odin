package ui

import "../animation"

// The shared scroll presentation primitive. Call once per visible scroll area;
// views receive a page plus a fractional offset and never implement easing.
scroll_page :: proc(s: ^State, scroll: ^animation.Scroll) -> (first: int, fraction: f32) {
	if animation.scroll_advance(scroll, s.p.frame_time) do s.is_animating = true
	return animation.scroll_page(scroll)
}
