-- The robot: a six axis arm with a camera eye on its gripper (fframes' arm.rs). Its parts are
-- view3d meshes in the frames of the joints they turn with, and its pose is a tree of groups;
-- the three wrist axes meet in one point, so the inverse kinematics is analytic. Transforms
-- are mat4s (three.js's Matrix4).

local A = {}

local PI, TAU = math.pi, 2 * math.pi
local sin, cos, atan, sqrt, abs = math.sin, math.cos, math.atan, math.sqrt, math.abs
local add, sub, sc, cross, norm = vec3_add, vec3_sub, vec3_scale, vec3_cross, vec3_normalize
local X, Y, Z = { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }

-- ------------------------------------------------------------------ frames

local function turn(e) return mat4_compose(nil, e) end
-- +Z along z, +X along x (made square to z)
function A.frame(x, z)
  z = norm(z)
  local y = norm(cross(z, x))
  return mat4_make_basis(cross(y, z), y, z)
end
-- the tool and the eye along `look`, the fingers level, turned by `roll`
function A.looking(look, roll)
  local z = norm(look)
  local side = vec3_length(cross(Y, z)) > 1e-9 and norm(cross(Y, z)) or X
  return mat4_multiply(A.frame(side, z), turn({ 0, 0, roll }))
end
A.TOOL_DOWN = A.frame(Z, { 0, -1, 0 })

-- ------------------------------------------------------------------ kinematics

local BASE_H, J2_UP, A1, L2, A3, L3, J4_AT, J6_OFF, GRIP = 0.45, 0.42, 0.16, 1.05, 0.12, 1.0, 0.62, 0.15, 0.24
A.GRIP, A.OPEN, A.EYE = GRIP, 0.12, { 0, 0.068, 0.1 }
local TIP, EYE = J6_OFF + GRIP, A.EYE
-- each joint: where it sits in its parent, and which way it turns
A.JOINT_AT = { { 0, BASE_H, 0 }, { 0, J2_UP, A1 }, { 0, L2, 0 }, { 0, A3, J4_AT }, { 0, 0, L3 - J4_AT },
  { 0, 0, J6_OFF } }
local AXES = { 2, 1, 1, 3, 1, 3 }
function A.joint_euler(q, i)
  local e = { 0, 0, 0 }
  e[AXES[i]] = q[i]
  return e
end
function A.joints_world(q)
  local out, m = {}, mat4_identity()
  for i = 1, 6 do
    m = mat4_multiply(m, mat4_compose(A.JOINT_AT[i], A.joint_euler(q, i)))
    out[i] = m
  end
  return out
end
function A.tip(q) return mat4_multiply(A.joints_world(q)[6], mat4_compose({ 0, 0, GRIP })) end
function A.eye(q) return vec3_apply_mat4(EYE, A.joints_world(q)[6]) end

local function unwrap(a, near) return a + round((near - a) / TAU) * TAU end
-- The joints that put the grip point at `p` with the tool frame `rot` (its +Z the tool axis,
-- +X the fingers), the wrist solution nearest `hint`.
function A.solve(p, rot, hint)
  local _, _, tool = mat4_extract_basis(rot)
  local wrist = sub(p, sc(tool, TIP))
  local q1 = unwrap(atan(wrist[1], wrist[3]), hint[1])
  local r = sqrt(wrist[1] ^ 2 + wrist[3] ^ 2) - A1
  local h = wrist[2] - (BASE_H + J2_UP)
  local l3, phi = sqrt(L3 * L3 + A3 * A3), atan(A3, L3)
  local d = clamp(sqrt(r * r + h * h), 0.05, L2 + l3 - 1e-3)
  -- elbow up
  local theta2 = atan(h, r) + math.acos(clamp((L2 * L2 + d * d - l3 * l3) / (2 * L2 * d), -1, 1))
  local theta3 = atan(h - L2 * sin(theta2), r - L2 * cos(theta2)) - phi
  local q2 = PI / 2 - theta2
  local q3 = -theta3 - q2
  -- the wrist: Rz(q4) Rx(q5) Rz(q6), in the forearm's frame
  local m = mat4_multiply(mat4_invert(mat4_multiply(turn({ 0, q1, 0 }), turn({ q2 + q3, 0, 0 }))), rot)
  local _, _, z = mat4_extract_basis(m)
  local b = math.acos(clamp(z[3], -1, 1))
  local cands = abs(sin(b)) < 1e-4 and { { hint[4], z[3] > 0 and 0 or PI } } or
    { { atan(z[1], -z[2]), b }, { atan(z[1], -z[2]) + PI, -b } }
  local best, cost
  for _, c in ipairs(cands) do
    local a = unwrap(c[1], hint[4])
    local x = mat4_extract_basis(mat4_multiply(mat4_invert(mat4_multiply(turn({ 0, 0, a }), turn({ c[2], 0, 0 }))), m))
    local q6 = unwrap(atan(x[2], x[1]), hint[6])
    local k = abs(a - hint[4]) + 0.5 * abs(q6 - hint[6]) + 0.3 * abs(c[2] - hint[5])
    if not cost or k < cost then best, cost = { q1, q2, q3, a, c[2], q6 }, k end
  end
  return best
end

-- ------------------------------------------------------------------ materials and parts

local function mat(color, roughness, metalness, extra)
  return merge({ type = "MeshPhysicalMaterial", color = color, roughness = roughness or 0.5, metalness = metalness or 0 },
    extra)
end
A.mat = mat
local P = {
  white = mat("#eeeeea", 0.36, 0, { clearcoat = 0.7, clearcoat_roughness = 0.05 }),
  graphite = mat("#2c2d31", 0.38, 1), chrome = mat("#e0e3e7", 0.1, 1), rubber = mat("#151517", 0.85),
  dark = mat("#18191b", 0.55, 1), yellow = mat("#f2bd00", 0.45),
  glass = mat("#05070a", 0.03, 0, { clearcoat = 1, clearcoat_roughness = 0.05, environment_intensity = 1.6 }),
  stripe = mat("#111111", 0.5, 0, { emissive = "#ff4a00", emissive_intensity = 1.6 }),
  leds = mat("#111111", 0.5, 0, { emissive = "#7dffb0", emissive_intensity = 3 }),
}
A.P = P

-- a mesh that casts and receives the key light's shadow
local function M(geometry, material, position, rotation, extra)
  return merge({ geometry = geometry, material = material, position = position, rotation = rotation, cast_shadow = true,
    receive_shadow = true }, extra)
end
A.M = M
local function cyl(top, bottom, h, segments)
  return { type = "CylinderGeometry", radius_top = top, radius_bottom = bottom, height = h, radial_segments = segments }
end
local function torus(r, tube, rs, ts)
  return { type = "TorusGeometry", radius = r, tube = tube, radial_segments = rs, tubular_segments = ts }
end
local function sphere(r, ws, hs)
  return { type = "SphereGeometry", radius = r, width_segments = ws, height_segments = hs }
end
-- an outline extruded `depth` thick with round edges inside it (fframes' extrude), and the
-- shift that centres it on z = 0
local function extruded(shape, depth, bevel, segments)
  local d = math.max(depth - 2 * bevel, 1e-4)
  return { type = "ExtrudeGeometry", shape = shape, depth = d, bevel_enabled = bevel > 0, bevel_thickness = bevel,
    bevel_size = bevel * 0.95, bevel_offset = -bevel * 0.95, bevel_segments = segments, crease_angle = PI / 4 }, -d / 2
end
local function rounded(w, h, d, r, segments)
  return { type = "RoundedBoxGeometry", width = w, height = h, depth = d, radius = r, segments = segments }
end
-- a rounded box at `p`, turned by `rot`
function A.rbox(w, h, d, r, segments, material, p, rot, extra)
  return M(rounded(w, h, d, r, segments), material, p, rot, extra)
end
-- copies of a rounded box, each { position, rotation, color }
function A.rboxes(w, h, d, r, segments, material, list)
  local inst = {}
  for i, c in ipairs(list) do inst[i] = { position = c[1], rotation = c[2], color = c[3] } end
  return M(rounded(w, h, d, r, segments), material, nil, nil, { instances = inst })
end
local rbox, rboxes = A.rbox, A.rboxes

-- the turn that points a Y-axis part (a cylinder) or a Z-axis part (a torus) along an axis
local function y_to(a)
  if a[1] ~= 0 then return { 0, 0, -a[1] * PI / 2 } end
  if a[3] ~= 0 then return { a[3] * PI / 2, 0, 0 } end
  return { a[2] < 0 and PI or 0, 0, 0 }
end
local function z_to(a)
  if a[1] ~= 0 then return { 0, a[1] * PI / 2, 0 } end
  if a[2] ~= 0 then return { -a[2] * PI / 2, 0, 0 } end
  return { a[3] < 0 and PI or 0, 0, 0 }
end
local function along(c, a, s) return add(c, sc(a, s)) end

-- hex bolt heads with washers on a circle facing the axis `n`
local function bolts(out, material, count, radius, bolt, center, n)
  local rot = y_to(n)
  local washers, heads = {}, {}
  for i = 0, count - 1 do
    local a = i / count * TAU
    local function on(h) return add(center, vec3_apply_euler({ cos(a) * radius, h, sin(a) * radius }, rot)) end
    washers[i + 1] = { position = on(bolt * 0.12), rotation = rot }
    heads[i + 1] = { position = on(bolt * 0.62), rotation = rot }
  end
  out[#out + 1] = M(cyl(bolt * 1.35, bolt * 1.35, bolt * 0.25, 16), material, nil, nil, { instances = washers })
  out[#out + 1] = M(cyl(bolt, bolt, bolt * 0.8, 6), material, nil, nil, { instances = heads })
end
-- a motor along `axis` from `a`: body, cooling fins, end cap with bolts and a connector
local function motor(out, a, axis, r, len)
  local side = abs(axis[2]) > 0.5 and Z or Y
  out[#out + 1] = M(cyl(r, r, len, 48), P.white, along(a, axis, len / 2), y_to(axis))
  local fins = {}
  for i = 0, 6 do
    fins[i + 1] = { position = along(a, axis, len * (0.15 + 0.6 * (i + 0.5) / 7)), rotation = z_to(axis) }
  end
  out[#out + 1] = M(torus(r + 0.004, 0.008, 6, 40), P.graphite, nil, nil, { instances = fins })
  out[#out + 1] = M(cyl(r * 0.92, r * 0.92, 0.03, 48), P.graphite, along(a, axis, len + 0.015), y_to(axis))
  bolts(out, P.chrome, 6, r * 0.7, 0.008, along(a, axis, len + 0.03), axis)
  local plug = along(a, axis, len * 0.85)
  out[#out + 1] = rbox(0.05, 0.05, 0.05, 0.012, 2, P.dark, add(plug, sc(side, r)))
  out[#out + 1] = M(cyl(0.016, 0.016, 0.03, 6), P.chrome, add(plug, sc(side, r + 0.035)), y_to(side))
end
-- a plate in the arm's side plane: the convex hull of circles { z, y, r }, `t` thick, centred
-- at x
local function plate(out, material, circles, t, bevel, x)
  local pts = {}
  for _, c in ipairs(circles) do
    for i = 0, 47 do pts[#pts + 1] = { c[1] + cos(i / 48 * TAU) * c[3], c[2] + sin(i / 48 * TAU) * c[3] } end
  end
  table.sort(pts, function(p, q) return p[1] < q[1] or (p[1] == q[1] and p[2] < q[2]) end)
  local hull = {}
  for pass = 1, 2 do
    local start = #hull
    local from, to, step = 1, #pts, 1
    if pass == 2 then from, to, step = #pts, 1, -1 end
    for k = from, to, step do
      local p = pts[k]
      while #hull >= start + 2 do
        local o, a = hull[#hull - 1], hull[#hull]
        if (a[1] - o[1]) * (p[2] - o[2]) - (a[2] - o[2]) * (p[1] - o[1]) > 0 then break end
        hull[#hull] = nil
      end
      hull[#hull + 1] = p
    end
    hull[#hull] = nil
  end
  local d = {}
  for i, p in ipairs(hull) do d[i] = string.format("%s%f %f", i == 1 and "M" or "L", -p[1], -p[2]) end
  local g, z = extruded(outline { d = table.concat(d, " ") .. " Z" }, t, bevel, 3)
  out[#out + 1] = M(g, material, { x + z, 0, 0 }, { 0, PI / 2, 0 })
end
-- raised lettering in Inter ExtraBold, centred on `p`
local function lettering(out, material, s, size, p, rot)
  local o = outline { s, font = "Inter 18pt", weight = 800, size = size }
  local x, y, w, h = outline_bounds(o)
  local g, z = extruded(o, 0.006, 0.0012, 2)
  out[#out + 1] = M(g, material, add(p, vec3_apply_euler({ -x - w / 2, y + h / 2, z }, rot)), rot)
end
-- a warning label facing +X: a yellow triangle with a black border and an exclamation mark
local function warning(out, p, size)
  local function tri(r, material, dx, dy)
    local d = string.format("M0 %f L%f %f L%f %f Z", -r, r * 0.866, r / 2, -r * 0.866, r / 2)
    local g = { type = "ExtrudeGeometry", shape = outline { d = d }, depth = 0.003, bevel_enabled = false }
    out[#out + 1] = M(g, material, add(p, { dx - 0.0015, dy, 0 }), { 0, PI / 2, 0 })
  end
  tri(size, P.dark, 0, 0)
  tri(size * 0.78, P.yellow, 0.002, -size * 0.04)
  local s = size
  out[#out + 1] = rbox(s * 0.12, s * 0.42, 0.003, s * 0.03, 1, P.dark, add(p, { 0.004, s * 0.02, 0 }), { 0, PI / 2, 0 })
  out[#out + 1] = M(cyl(s * 0.07, s * 0.07, 0.003, 12), P.dark, add(p, { 0.004, -s * 0.32, 0 }), { 0, 0, PI / 2 })
end

-- The parts: `base` in the world, `j[1..6]` in their joints, `fingers[1..2]` (in J6, moved
-- along X by the gap).
function A.parts()
  local base, J, fingers = {}, { {}, {}, {}, {}, {}, {} }, { {}, {} }
  -- the base, bolted to the floor
  base[#base + 1] = rbox(1, 0.05, 1, 0.02, 3, P.graphite, { 0, 0.025, 0 })
  for _, xz in ipairs { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 }, { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
    bolts(base, P.chrome, 1, 0, 0.026, { xz[1] * 0.43, 0.05, xz[2] * 0.43 }, Y)
  end
  -- the column, turned from a profile
  base[#base + 1] = M({ type = "LatheGeometry", segments = 96, points = { { 0.36, 0.05 }, { 0.36, 0.09 }, { 0.31, 0.13 },
    { 0.3, 0.37 }, { 0.335, 0.405 }, { 0.335, 0.45 }, { 0, 0.45 } } }, P.white)
  local ribs, links, chain = {}, {}, {}
  for i = 0, 27 do
    local turn = { 0, i / 28 * TAU, 0 }
    ribs[i + 1] = { vec3_apply_euler({ 0, 0.25, 0.3 }, turn), turn }
  end
  base[#base + 1] = rboxes(0.014, 0.2, 0.045, 0.005, 1, P.graphite, ribs)
  -- the cable's drag chain into a box on the floor
  for i = 0, 40 do
    local t = i / 40
    chain[i + 1] = { -0.9 * t, 0.06 + 0.16 * sin(t * PI) * (1 - t * 0.5), -0.45 - 0.55 * t }
  end
  for i = 1, 39, 2 do
    local d = norm(sub(chain[i + 1], chain[i]))
    links[#links + 1] = { vec3_lerp(chain[i], chain[i + 1], 0.5), { atan(-d[2], d[3]), math.asin(d[1]), 0 } }
  end
  base[#base + 1] = rboxes(0.09, 0.05, 0.06, 0.01, 1, P.dark, links)
  base[#base + 1] = rbox(0.18, 0.14, 0.1, 0.02, 2, P.dark, { 0, 0.2, -0.32 })
  base[#base + 1] = rbox(0.32, 0.16, 0.24, 0.03, 2, P.graphite, { -0.98, 0.08, -1.02 })
  base[#base + 1] = rbox(0.2, 0.004, 0.12, 0.002, 1, P.yellow, { -0.98, 0.162, -1.02 })

  -- J1: the turret
  local j = J[1]
  j[#j + 1] = M(cyl(0.34, 0.345, 0.07, 96), P.graphite, { 0, 0.035, 0 })
  bolts(j, P.chrome, 16, 0.3, 0.011, { 0, 0.07, 0 }, Y)
  for _, x in ipairs { -0.25, 0.25 } do
    plate(j, P.white, { { A1, J2_UP, 0.235 }, { -0.08, 0.13, 0.22 }, { 0.18, 0.1, 0.2 } }, 0.09, 0.025, x)
    plate(j, P.graphite, { { A1, J2_UP, 0.17 }, { -0.04, 0.16, 0.15 } }, 0.02, 0.006, x * 1.24)
  end
  j[#j + 1] = rbox(0.42, 0.18, 0.44, 0.05, 3, P.white, { 0, 0.13, 0.02 })
  local vents = {}
  for i = 0, 5 do vents[i + 1] = { { 0, 0.08 + i * 0.022, 0.245 } } end
  j[#j + 1] = rboxes(0.22, 0.012, 0.01, 0.004, 1, P.dark, vents)
  motor(j, { 0, 0.1, -0.33 }, Y, 0.1, 0.3)
  motor(j, { -0.33, J2_UP, A1 }, { -1, 0, 0 }, 0.125, 0.22)
  j[#j + 1] = M(cyl(0.2, 0.2, 0.42, 48), P.graphite, { 0, J2_UP, A1 }, { 0, 0, PI / 2 })
  for _, x in ipairs { -0.302, 0.302 } do
    j[#j + 1] = M(cyl(0.12, 0.12, 0.02, 48), P.chrome, { x, J2_UP, A1 }, { 0, 0, PI / 2 })
    bolts(j, P.chrome, 10, 0.155, 0.01, { x * 1.03, J2_UP, A1 }, { sign(x), 0, 0 })
  end
  warning(j, { 0.30, 0.17, -0.02 }, 0.045)
  lettering(j, P.dark, "07", 0.11, { -0.30, 0.18, -0.03 }, { 0, -PI / 2, 0 })

  -- J2: the upper arm
  j = J[2]
  plate(j, P.white, { { 0, 0, 0.19 }, { 0, L2, 0.15 } }, 0.3, 0.035, 0)
  for _, x in ipairs { -0.155, 0.155 } do
    plate(j, P.graphite, { { 0, 0.25, 0.1 }, { 0, L2 - 0.25, 0.08 } }, 0.016, 0.005, x)
    lettering(j, P.chrome, "FFRAMES", 0.06, { x * 1.06, L2 * 0.52, 0 }, { 0, sign(x) * PI / 2, PI / 2 })
  end
  j[#j + 1] = rbox(0.004, L2 * 0.5, 0.012, 0.002, 1, P.stripe, { 0.165, L2 * 0.5, 0.11 })
  -- a corrugated hose and a cable up its back
  local hose, cable, rings = {}, {}, {}
  for i = 0, 16 do
    local t = i / 16
    hose[i + 1] = { 0.09, 0.08 + t * (L2 - 0.16), -0.2 - 0.05 * sin(t * PI) }
    cable[i + 1] = add(hose[i + 1], { -0.07, 0, 0.005 })
  end
  j[#j + 1] = M({ type = "TubeGeometry", points = hose, radius = 0.024, radial_segments = 14 }, P.rubber)
  j[#j + 1] = M({ type = "TubeGeometry", points = cable, radius = 0.014, radial_segments = 12 }, P.dark)
  for s = 0.035, L2 - 0.16, 0.035 do
    local t = s / (L2 - 0.16)
    local p = { 0.09, 0.08 + s, -0.2 - 0.05 * sin(t * PI) }
    local d = norm({ 0, 1, -0.05 * PI * cos(t * PI) / (L2 - 0.16) })
    rings[#rings + 1] = { position = p, rotation = { atan(d[3], d[2]) + PI / 2, 0, 0 } }
  end
  j[#j + 1] = M(torus(0.0245, 0.0043, 6, 18), P.rubber, nil, nil, { instances = rings })
  local clamps = {}
  for i = 1, 3 do clamps[i] = { { 0.055, 0.08 + i * 0.25, -0.2 - 0.05 * sin(i * 0.25 / 0.9 * PI) } } end
  j[#j + 1] = rboxes(0.16, 0.03, 0.07, 0.01, 2, P.chrome, clamps)
  j[#j + 1] = M(torus(0.022, 0.006, 8, 20), P.chrome, nil, nil,
    { instances = { { position = { 0, 0.35, 0.17 } }, { position = { 0, 0.75, 0.17 } } } })
  j[#j + 1] = M(cyl(0.16, 0.16, 0.36, 48), P.graphite, { 0, L2, 0 }, { 0, 0, PI / 2 })
  for _, x in ipairs { -0.19, 0.19 } do
    j[#j + 1] = M(cyl(0.09, 0.09, 0.02, 48), P.chrome, { x, L2, 0 }, { 0, 0, PI / 2 })
    bolts(j, P.chrome, 8, 0.12, 0.009, { x * 1.06, L2, 0 }, { sign(x), 0, 0 })
  end
  motor(j, { 0.18, L2, 0 }, X, 0.1, 0.16)

  -- J3: the forearm, with the three wrist motors at the back
  j = J[3]
  j[#j + 1] = rbox(0.3, 0.3, 0.34, 0.07, 4, P.white, { 0, A3, -0.18 })
  local grille = {}
  for i = 0, 4 do
    grille[#grille + 1] = { { 0.152, A3, -0.26 + i * 0.03 } }
    grille[#grille + 1] = { { -0.152, A3, -0.26 + i * 0.03 } }
  end
  j[#j + 1] = rboxes(0.012, 0.16, 0.01, 0.004, 1, P.dark, grille)
  for _, xy in ipairs { { -0.07, 0.07 }, { 0.07, 0.07 }, { 0, -0.07 } } do
    motor(j, { xy[1], A3 + xy[2], -0.35 }, { 0, 0, -1 }, 0.05, 0.12)
  end
  j[#j + 1] = M(cyl(0.105, 0.13, 0.5, 64), P.white, { 0, A3, 0.27 }, { PI / 2, 0, 0 })
  j[#j + 1] = M(torus(0.11, 0.012, 10, 64), P.graphite, { 0, A3, 0.535 })
  local leds = {}
  for i = 0, 2 do leds[i + 1] = { position = { 0, A3 + 0.12, 0.2 + i * 0.03 } } end
  j[#j + 1] = M(sphere(0.007, 12, 6), P.leds, nil, nil, { instances = leds })
  warning(j, { 0.118, A3 + 0.02, 0.35 }, 0.035)

  -- J4: the front of the forearm rolls
  j = J[4]
  j[#j + 1] = M(torus(0.1, 0.01, 10, 64), P.graphite, { 0, 0, -0.06 })
  j[#j + 1] = M(cyl(0.095, 0.1, 0.24, 64), P.white, { 0, 0, 0.06 }, { PI / 2, 0, 0 })
  j[#j + 1] = M(torus(0.092, 0.008, 8, 64), P.graphite, { 0, 0, 0.19 }, { PI / 2, 0, 0 })
  bolts(j, P.chrome, 8, 0.075, 0.006, { 0, 0, 0.18 }, Z)
  for _, x in ipairs { -0.085, 0.085 } do
    plate(j, P.graphite, { { 0.2, 0, 0.06 }, { L3 - J4_AT, 0, 0.075 } }, 0.03, 0.008, x)
  end

  -- J5: the wrist
  j = J[5]
  j[#j + 1] = M(cyl(0.065, 0.065, 0.14, 48), P.white, { 0, 0, 0 }, { 0, 0, PI / 2 })
  for _, x in ipairs { -0.104, 0.104 } do
    j[#j + 1] = M(cyl(0.045, 0.045, 0.012, 48), P.chrome, { x, 0, 0 }, { 0, 0, PI / 2 })
    bolts(j, P.dark, 5, 0.032, 0.005, { x * 1.08, 0, 0 }, { sign(x), 0, 0 })
  end
  j[#j + 1] = M(cyl(0.055, 0.06, 0.13, 48), P.white, { 0, 0, 0.08 }, { PI / 2, 0, 0 })

  -- J6: the flange, the tool changer, the gripper and the camera eye
  j = J[6]
  j[#j + 1] = M(cyl(0.068, 0.068, 0.022, 48), P.chrome, { 0, 0, 0.011 }, { PI / 2, 0, 0 })
  bolts(j, P.dark, 6, 0.05, 0.007, { 0, 0, 0.022 }, Z)
  j[#j + 1] = M(cyl(0.058, 0.058, 0.03, 48), P.graphite, { 0, 0, 0.04 }, { PI / 2, 0, 0 })
  j[#j + 1] = M(torus(0.058, 0.004, 6, 48), P.chrome, { 0, 0, 0.056 }, { PI / 2, 0, 0 })
  j[#j + 1] = rbox(0.26, 0.085, 0.08, 0.02, 3, P.graphite, { 0, 0, 0.104 })
  j[#j + 1] = rboxes(0.24, 0.016, 0.014, 0.005, 1, P.chrome, { { { 0, 0.035, 0.15 } }, { { 0, -0.035, 0.15 } } })
  local screws = {}
  for i, x in ipairs { -0.1, -0.05, 0.05, 0.1 } do screws[i] = { position = { x, -0.044, 0.104 } } end
  j[#j + 1] = M(cyl(0.006, 0.006, 0.006, 6), P.chrome, nil, nil, { instances = screws })
  for _, x in ipairs { -0.07, 0.07 } do
    j[#j + 1] = M(cyl(0.011, 0.011, 0.03, 12), P.chrome, { x, -0.05, 0.08 })
    local hose = { { x, -0.06, 0.08 }, { x * 0.8, -0.1, 0.03 }, { x * 0.4, -0.1, -0.05 }, { 0, -0.08, -0.12 } }
    j[#j + 1] = M({ type = "TubeGeometry", points = hose, radius = 0.007, radial_segments = 8 }, P.rubber)
  end
  j[#j + 1] = rbox(0.11, 0.06, 0.09, 0.018, 3, P.white, { EYE[1], EYE[2] - 0.002, EYE[3] - 0.04 })
  j[#j + 1] = M(cyl(0.026, 0.03, 0.03, 40), P.graphite, add(EYE, { 0, 0, 0.015 }), { PI / 2, 0, 0 })
  j[#j + 1] = M(torus(0.024, 0.004, 8, 40), P.chrome, add(EYE, { 0, 0, 0.03 }))
  -- the lens: a 60 degree cap of a sphere
  j[#j + 1] = M({ type = "SphereGeometry", radius = 0.021, width_segments = 32, height_segments = 12,
    theta_length = PI / 3 }, P.glass, add(EYE, { 0, 0, 0.02 }), { PI / 2, 0, 0 })
  for k, x in ipairs { -1, 1 } do
    local f = fingers[k]
    f[#f + 1] = rbox(0.03, 0.06, 0.07, 0.008, 2, P.graphite, { x * 0.015, 0, 0.155 })
    f[#f + 1] = rbox(0.024, 0.055, 0.12, 0.007, 2, P.white, { x * 0.012, 0, 0.215 })
    f[#f + 1] = rbox(0.008, 0.05, 0.06, 0.003, 1, P.rubber, { -x * 0.003, 0, 0.245 })
    local pins = { { position = { x * 0.031, 0, 0.14 }, rotation = { 0, 0, PI / 2 } },
      { position = { x * 0.031, 0, 0.17 }, rotation = { 0, 0, PI / 2 } } }
    f[#f + 1] = M(cyl(0.005, 0.005, 0.004, 6), P.chrome, nil, nil, { instances = pins })
  end
  return base, J, fingers
end

-- The gas spring between the turret and the upper arm, at the joints' world transforms.
function A.spring(world)
  local a, b = vec3_apply_mat4({ 0, 0.16, -0.27 }, world[1]), vec3_apply_mat4({ 0, 0.42, -0.19 }, world[2])
  local d = norm(sub(b, a))
  return {
    M(cyl(0.045, 0.045, 0.42, 32), P.graphite, nil, nil, { from = a, to = along(a, d, 0.42) }),
    M(torus(0.046, 0.005, 6, 32), P.chrome, nil, nil, { from = along(a, d, 0.4), to = along(a, d, 0.41) }),
    M(sphere(0.05, 24, 12), P.chrome, a),
    M(cyl(0.018, 0.018, 0.45, 16), P.chrome, nil, nil, { from = b, to = along(b, d, -0.45) }),
    M(sphere(0.035, 24, 12), P.chrome, b),
  }
end

return A
