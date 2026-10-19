package onimite_script

import "core:math/linalg"
import "core:testing"
import b3 "vendor:box3d"

@(test)
test_convex_pieces :: proc(t: ^testing.T) {
	pieces, starts: [dynamic]u32
	defer delete(pieces)
	defer delete(starts)

	// A square fanned from its centre: one piece.
	sq := [][2]f32{{0, 0}, {10, 0}, {10, 10}, {0, 10}, {5, 5}}
	fan := [][3]u32{{4, 0, 1}, {4, 1, 2}, {4, 2, 3}, {4, 3, 0}}
	convex_pieces(sq, fan, 8, &pieces, &starts)
	testing.expect_value(t, len(starts) - 1, 1)

	// An L (a reflex corner at 3): two pieces, all six corners used.
	l := [][2]f32{{0, 0}, {20, 0}, {20, 10}, {10, 10}, {10, 20}, {0, 20}}
	tris := [][3]u32{{0, 1, 2}, {0, 2, 3}, {0, 3, 4}, {0, 4, 5}}
	convex_pieces(l, tris, 8, &pieces, &starts)
	testing.expect_value(t, len(starts) - 1, 2)

	// The same L with pieces of at most 3 corners: the four triangles.
	convex_pieces(l, tris, 3, &pieces, &starts)
	testing.expect_value(t, len(starts) - 1, 4)

	// Mixed windings come back one way, and every piece is convex.
	mixed := [][3]u32{{0, 2, 1}, {0, 2, 3}, {0, 4, 3}, {0, 4, 5}}
	convex_pieces(l, mixed, 8, &pieces, &starts)
	testing.expect_value(t, len(starts) - 1, 2)
	for k in 0 ..< len(starts) - 1 {
		r := pieces[starts[k]:starts[k + 1]]
		for i in 0 ..< len(r) {
			a, b, c := l[r[i]], l[r[(i + 1) % len(r)]], l[r[(i + 2) % len(r)]]
			testing.expect(t, (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) <= 0)
		}
	}
}

// The local overrides of vendor:box3d's quaternion helpers agree with Odin's
// quaternion math (identity included: the broken port doubled vectors there).
@(test)
test_b3_overrides :: proc(t: ^testing.T) {
	qs := []b3.Quat{1, linalg.normalize(b3.Quat(quaternion(x = 0.3, y = -0.5, z = 0.2, w = 0.8))), linalg.normalize(b3.Quat(quaternion(x = -0.7, y = 0.1, z = 0.4, w = -0.2)))}
	v := b3.Vec3{0.3, -1.2, 2.5}
	for q1 in qs {
		testing.expect(t, linalg.length(b3_rotate_vector(q1, v) - linalg.quaternion_mul_vector3(q1, v)) < 1e-5)
		testing.expect(t, linalg.length(b3_inv_rotate_vector(q1, v) - linalg.quaternion_mul_vector3(conj(q1), v)) < 1e-5)
		xf := b3.Transform{p = {1, 2, 3}, q = q1}
		testing.expect(t, linalg.length(b3_inv_transform_point(xf, b3_transform_point(xf, v)) - v) < 1e-5)
		for q2 in qs {
			d := b3_inv_mul_quat(q1, q2) - conj(q1) * q2
			testing.expect(t, abs(d.x) + abs(d.y) + abs(d.z) + abs(d.w) < 1e-5)
		}
	}
}
