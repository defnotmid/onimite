package animation

import "core:math"
import "core:testing"

@(test)
test_retarget_preserves_register_and_frame_rate_independence :: proc(t: ^testing.T) {
	a, b: f32 = 1, 1
	ta, tb: Track
	target(&ta, a, 100, space = .Logarithmic, rate = 18); tb = ta
	for _ in 0 ..< 60 do advance(&a, &ta, 1.0 / 60)
	for _ in 0 ..< 120 do advance(&b, &tb, 1.0 / 120)
	testing.expect(t, math.abs(a - b) < 1e-3)
	target(&ta, a, 0.1, space = .Logarithmic)
	testing.expect_value(t, a, b)
	advance(&a, &ta, 0.05)
	testing.expect(t, a > 0.1 && a < b)
	target(&ta, a, 30, space = .Logarithmic)
	testing.expect_value(t, ta.start, a)
	advance(&a, &ta, 1)
	testing.expect_value(t, a, f32(30))
	testing.expect(t, !ta.active)
	testing.expect_value(t, b, f32(100))
}

@(test)
test_scroll_fraction_bounds_and_independent_registers :: proc(t: ^testing.T) {
	rows: [2]Scroll
	scroll_limit(&rows[0], 100); scroll_limit(&rows[1], 100)
	scroll_by(&rows[0], 4.5)
	scroll_advance(&rows[0], 0.025)
	first, fraction := scroll_page(&rows[0])
	testing.expect(t, first >= 0 && fraction > 0 && fraction < 1)
	testing.expect_value(t, rows[1].current, f32(0))
	// Repeated input accumulates against the target, not the lagging display.
	scroll_by(&rows[0], 2)
	testing.expect_value(t, rows[0].track.target, f32(6.5))
	scroll_limit(&rows[0], 2)
	for _ in 0 ..< 20 do scroll_advance(&rows[0], 0.02)
	testing.expect_value(t, rows[0].current, f32(2))
	scroll_limit(&rows[0], 0)
	testing.expect_value(t, rows[0].current, f32(0))
	testing.expect(t, !rows[0].track.active)
}
