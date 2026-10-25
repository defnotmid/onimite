package animation

// A scroll register may use pixels, rows or sample indexes. The owner supplies
// bounds; interpolation, clamping and fractional paging are shared primitives.
Scroll :: struct {
	current, maximum: f32,
	track:            Track,
}
scroll_to :: proc(s: ^Scroll, requested: f32) {
	value := clamp(requested, 0, s.maximum)
	if value != s.track.target do target(&s.track, s.current, value)
}
scroll_by :: proc(s: ^Scroll, delta: f32) {scroll_to(s, s.track.target + delta)}
scroll_limit :: proc(s: ^Scroll, maximum: f32) {
	s.maximum = max(0, maximum)
	s.current = clamp(s.current, 0, s.maximum)
	value := clamp(s.track.target, 0, s.maximum)
	if value != s.track.target || s.current == value do target(&s.track, s.current, value)
}
scroll_advance :: proc(s: ^Scroll, dt: f32) -> bool {return advance(&s.current, &s.track, dt)}
scroll_page :: proc(s: ^Scroll) -> (first: int, fraction: f32) {
	first = int(max(0, s.current))
	fraction = s.current - f32(first)
	return
}
