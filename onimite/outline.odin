package onimite

import "core:math"
import "deps:o3d"
import cv "deps:ocurves"
import vg "deps:ovg"

// The outline flattened into `out`, curves split about every `segment`
// outline units, or (0) finely at any scale: about 1/1300 of its size, so a
// 1-unit letter for 3D keeps round bowls. (ovg flattens about every 1.5
// units: the path is scaled to suit first.)
outline_flatten :: proc(a: ^Path_Asset, out: ^vg.Flat_Path, segment: f32 = 0) {
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
	for v in a.path.pts {
		lo, hi = {min(lo.x, v.x), min(lo.y, v.y)}, {max(hi.x, v.x), max(hi.y, v.y)}
	}
	span := max(hi.x - lo.x, hi.y - lo.y)
	seg: f32 = 1.5
	if segment > 0 {
		seg = segment
	} else if span > 0 && len(a.path.pts) > 0 {
		seg = span * 1.5 / 2000
	}
	vg.path_flatten(&a.path, out, seg)
}

// The outline's contours appended to `c`; `flip_y` for 3D (y up), where
// text then reads upright.
outline_contours :: proc(a: ^Path_Asset, c: ^cv.Contours, flip_y: bool) {
	vg.path_append(c, &a.path, {1, 0, 0, -1, 0, 0} if flip_y else vg.TRANSFORM_IDENTITY)
}

// The outline as o3d shapes, written over `s`: what its fill rule fills, as
// outlines with their holes, each curve taking `curve_segments` points (as
// three.js flattens it); `flip_y` for 3D (y up).
outline_shapes :: proc(a: ^Path_Asset, s: ^o3d.Shapes, flip_y: bool, curve_segments := 12) -> cv.Bool_Error {
	c: cv.Contours
	cv.contours_init(&c, context.temp_allocator)
	outline_contours(a, &c, flip_y)
	return o3d.shapes_from_contours(s, &c, a.fill_rule, curve_segments)
}

// Drops the points of `s`'s rings within `tol` of the simplified ring
// (`simplify_ring`), and the rings and shapes left without area: physics
// wants corners with a real turn.
shapes_simplify :: proc(s: ^o3d.Shapes, tol: f32) {
	points := make([dynamic]o3d.Vec2, 0, len(s.points), context.temp_allocator)
	rings := make([dynamic][2]u32, 0, len(s.rings), context.temp_allocator)
	shapes := make([dynamic][2]u32, 0, len(s.shapes), context.temp_allocator)
	for sh in s.shapes {
		first := len(rings)
		for k in sh[0] ..< sh[0] + sh[1] {
			ring := simplify_ring(o3d.shapes_ring(s, int(k)), tol)
			if len(ring) < 3 {
				if k == sh[0] {
					break // the outline has no area: nor has the shape
				}
				continue
			}
			append(&rings, [2]u32{u32(len(points)), u32(len(ring))})
			append(&points, ..ring)
		}
		if len(rings) > first {
			append(&shapes, [2]u32{u32(first), u32(len(rings) - first)})
		}
	}
	clear(&s.points)
	clear(&s.rings)
	clear(&s.shapes)
	append(&s.points, ..points[:])
	append(&s.rings, ..rings[:])
	append(&s.shapes, ..shapes[:])
}

// A closed ring with the points within `tol` of the simplified outline left
// out (Douglas-Peucker from the point farthest from the first), temp
// allocated.
@(private)
simplify_ring :: proc(ring: []o3d.Vec2, tol: f32) -> []o3d.Vec2 {
	n := len(ring)
	if n < 4 {
		return ring
	}
	keep := make([]bool, n, context.temp_allocator)
	far, best := 0, f32(-1)
	for p, i in ring {
		d := p - ring[0]
		if dd := d.x * d.x + d.y * d.y; dd > best {
			far, best = i, dd
		}
	}
	keep[0], keep[far] = true, true
	// Spans to refine, as index pairs (the second half wraps to 0 as n).
	stack := make([dynamic][2]int, 0, 32, context.temp_allocator)
	append(&stack, [2]int{0, far}, [2]int{far, n})
	for len(stack) > 0 {
		span := pop(&stack)
		a, b := ring[span[0]], ring[span[1] % n]
		ab := b - a
		l := max(math.sqrt(ab.x * ab.x + ab.y * ab.y), 1e-12)
		worst, at := f32(0), -1
		for i in span[0] + 1 ..< span[1] {
			p := ring[i] - a
			if d := abs(ab.x * p.y - ab.y * p.x) / l; d > worst {
				worst, at = d, i
			}
		}
		if at >= 0 && worst > tol {
			keep[at] = true
			append(&stack, [2]int{span[0], at}, [2]int{at, span[1]})
		}
	}
	out := make([dynamic]o3d.Vec2, 0, n, context.temp_allocator)
	for p, i in ring {
		if keep[i] {
			append(&out, p)
		}
	}
	return out[:]
}
