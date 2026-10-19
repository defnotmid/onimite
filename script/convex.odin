package onimite_script

import "core:slice"

// Convex pieces of a triangulated polygon (Hertel-Mehlhorn): triangles
// sharing an edge merge while the union stays convex and has at most
// `max_verts` corners, longest shared edges first (fewer slivers). A body
// made from an outline gets one Box2D polygon (8 corners at most) or one
// Box3D hull per piece. Pieces come back as index runs into `points`:
// piece k is pieces[starts[k]:starts[k + 1]], counter-clockwise in the
// orientation of the first triangle with area.
convex_pieces :: proc(points: [][2]f32, tris: [][3]u32, max_verts: int, pieces: ^[dynamic]u32, starts: ^[dynamic]u32) {
	clear(pieces)
	clear(starts)
	append(starts, 0)
	n := len(tris)
	if n == 0 {
		return
	}
	area2 :: proc(a, b, c: [2]f32) -> f32 {
		return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	}
	// Every triangle turned one way (the sign of the first with area).
	sign: f32 = 0
	for t in tris {
		if a := area2(points[t[0]], points[t[1]], points[t[2]]); a != 0 {
			sign = 1 if a > 0 else -1
			break
		}
	}
	if sign == 0 {
		return
	}
	rings := make([][dynamic]u32, n, context.temp_allocator)
	parent := make([]int, n, context.temp_allocator)
	for t, i in tris {
		r := make([dynamic]u32, 0, 4, context.temp_allocator)
		if area2(points[t[0]], points[t[1]], points[t[2]]) * sign >= 0 {
			append(&r, t[0], t[1], t[2])
		} else {
			append(&r, t[0], t[2], t[1])
		}
		rings[i] = r
		parent[i] = i
	}

	// Shared edges: the two triangles on either side of each.
	Edge :: struct {
		u, v: u32,
		a, b: int,
		len2: f32,
	}
	sides := make(map[u64]int, 3 * n, context.temp_allocator)
	edges := make([dynamic]Edge, 0, n, context.temp_allocator)
	for t, i in tris {
		for k in 0 ..< 3 {
			u, v := t[k], t[(k + 1) % 3]
			key := u64(min(u, v)) << 32 | u64(max(u, v))
			if j, seen := sides[key]; seen {
				d := points[u] - points[v]
				append(&edges, Edge{u = u, v = v, a = j, b = i, len2 = d.x * d.x + d.y * d.y})
			} else {
				sides[key] = i
			}
		}
	}
	slice.sort_by(edges[:], proc(x, y: Edge) -> bool {return x.len2 > y.len2})

	find :: proc(parent: []int, i: int) -> int {
		i := i
		for parent[i] != i {
			parent[i] = parent[parent[i]]
			i = parent[i]
		}
		return i
	}
	// The index of `u` in ring r when the ring steps u -> v, else -1.
	step_at :: proc(r: []u32, u, v: u32) -> int {
		for x, k in r {
			if x == u && r[(k + 1) % len(r)] == v {
				return k
			}
		}
		return -1
	}
	merged := make([dynamic]u32, 0, max_verts + 2, context.temp_allocator)
	for e in edges {
		a, b := find(parent, e.a), find(parent, e.b)
		if a == b || len(rings[a]) + len(rings[b]) - 2 > max_verts {
			continue
		}
		ra, rb := rings[a][:], rings[b][:]
		// One ring walks the edge u -> v, the other v -> u.
		ia, ib := step_at(ra, e.u, e.v), step_at(rb, e.v, e.u)
		if ia < 0 {
			ra, rb = rb, ra
			a, b = b, a
			ia, ib = step_at(ra, e.u, e.v), step_at(rb, e.v, e.u)
		}
		if ia < 0 || ib < 0 {
			continue
		}
		// v .. u around a, then b's corners after u up to v.
		clear(&merged)
		for k in 1 ..= len(ra) {
			append(&merged, ra[(ia + k) % len(ra)])
		}
		for k in 2 ..< len(rb) {
			append(&merged, rb[(ib + k) % len(rb)])
		}
		convex := true
		m := len(merged)
		for k in 0 ..< m {
			p0, p1, p2 := points[merged[k]], points[merged[(k + 1) % m]], points[merged[(k + 2) % m]]
			// Collinear corners pass (a rounding hair below zero too).
			if area2(p0, p1, p2) * sign < -1e-4 * (abs(p1.x - p0.x) + abs(p1.y - p0.y)) * (abs(p2.x - p1.x) + abs(p2.y - p1.y)) {
				convex = false
				break
			}
		}
		if !convex {
			continue
		}
		clear(&rings[a])
		append(&rings[a], ..merged[:])
		parent[b] = a
	}
	for r, i in rings {
		if parent[i] == i {
			append(pieces, ..r[:])
			append(starts, u32(len(pieces)))
		}
	}
}
