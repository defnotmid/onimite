package onimite

import "core:math"
import "core:mem"
import "core:strings"
import vg "deps:ovg"

// A frame is a tree of nodes built by the render procs and drawn after they
// return. Builders copy strings and slices into the frame's arena, so
// temporary arguments (`fmt.tprintf`, slice literals) are safe.
//
//     om.rect(ctx, {x = 100, y = 100, w = 200, h = 80, rx = 16, fill = om.hex("#0ea5e9")})
//     {
//         om.group(ctx, {transform = om.translate(0, y), opacity = alpha})
//         om.text(ctx, {text = "Hello", x = 120, y = 150, font = "Inter", size = 48, fill = om.WHITE})
//     } // the group closes at the end of the block

// Decomposed 2D transform; animatable with `animate`. Applied as
// translate(translate) * rotate/scale around `origin`.
Transform :: struct {
	translate: Vec2,
	scale:     Vec2,
	// Degrees, clockwise (SVG convention).
	rotate:    f32,
	// Degrees along x and y (SVG skewX / skewY), applied after scaling.
	skew:      Vec2,
	origin:    Vec2,
	// An SVG matrix (a b c d e f); when set it is the whole transform and the
	// fields above are ignored.
	affine:    Maybe(vg.Transform2D),
}

IDENTITY :: Transform {
	scale = {1, 1},
}

translate :: proc "contextless" (x, y: f32) -> Transform {
	return {translate = {x, y}, scale = {1, 1}}
}

scale :: proc "contextless" (sx, sy: f32, origin: Vec2 = {}) -> Transform {
	return {scale = {sx, sy}, origin = origin}
}

rotate :: proc "contextless" (degrees: f32, origin: Vec2 = {}) -> Transform {
	return {scale = {1, 1}, rotate = degrees, origin = origin}
}

skew :: proc "contextless" (x_degrees, y_degrees: f32, origin: Vec2 = {}) -> Transform {
	return {scale = {1, 1}, skew = {x_degrees, y_degrees}, origin = origin}
}

// An SVG matrix as a Transform.
affine :: proc "contextless" (m: vg.Transform2D) -> Transform {
	return {scale = {1, 1}, affine = m}
}

transform_matrix :: proc "contextless" (t: Transform) -> vg.Transform2D {
	if m, ok := t.affine.?; ok {
		return m
	}
	m := vg.transform_translation(-t.origin.x, -t.origin.y)
	m = vg.transform_multiply(m, vg.transform_scaling(t.scale.x, t.scale.y))
	if t.skew.x != 0 {
		m = vg.transform_multiply(m, vg.transform_skew_x(t.skew.x * math.RAD_PER_DEG))
	}
	if t.skew.y != 0 {
		m = vg.transform_multiply(m, vg.transform_skew_y(t.skew.y * math.RAD_PER_DEG))
	}
	m = vg.transform_multiply(m, vg.transform_rotation(t.rotate * math.RAD_PER_DEG))
	m = vg.transform_multiply(m, vg.transform_translation(t.origin.x + t.translate.x, t.origin.y + t.translate.y))
	return m
}

// ---- paints and styles -----------------------------------------------------------

// Coordinates of a gradient or pattern: user units, or fractions of the
// painted shape's bounding box (SVG objectBoundingBox).
Paint_Units :: enum u8 {
	User,
	Bounding_Box,
}

// Shared by gradients and patterns: units, SVG gradientTransform /
// patternTransform, and spreadMethod.
Paint_Space :: struct {
	units:     Paint_Units,
	transform: Maybe(vg.Transform2D),
	spread:    vg.Gradient_Spread,
}

Linear_Gradient :: struct {
	x1, y1, x2, y2: f32,
	stops:          []vg.Gradient_Stop,
	using space:    Paint_Space,
}

Radial_Gradient :: struct {
	cx, cy:      f32,
	// The gradient runs from `inner_r` (first stop) to `r` (last stop).
	inner_r, r:  f32,
	// SVG fx / fy: the focal point the gradient starts from (a circle of
	// radius `inner_r` there, SVG fr); nil is the center.
	focal:       Maybe(Vec2),
	stops:       []vg.Gradient_Stop,
	using space: Paint_Space,
}

// A tile drawn by the nodes under `content` (a hidden group, see
// `pattern_begin`), repeated from (x, y) every (w, h).
Pattern :: struct {
	content:     i32,
	x, y, w, h:  f32,
	using space: Paint_Space,
}

// `nil` paints nothing.
Paint :: union {
	Color,
	Linear_Gradient,
	Radial_Gradient,
	Pattern,
}

Stroke :: struct {
	paint:       Paint,
	width:       f32,
	cap:         vg.Line_Cap,
	join:        vg.Line_Join,
	// SVG stroke-miterlimit; 0 means 4.
	miter_limit: f32,
	// SVG stroke-opacity (nil = 1).
	opacity:     Maybe(f32),
	// Dash pattern (on, off, on, ...) and where it starts; empty is solid.
	dash:        []f32,
	dash_offset: f32,
	// When > 0, dash lengths and offset are fractions of this length rather
	// than units (SVG `pathLength`): `path_length = 1` with dash {1, 1} and an
	// offset going 1 -> 0 draws the path on.
	path_length: f32,
}

// ---- nodes -------------------------------------------------------------------------

Group :: struct {
	transform: Maybe(Transform),
	// Applied to the group as a whole (children are composited first).
	opacity:   Maybe(f32),
	// Clips children to a rectangle in the group's (transformed) space.
	clip:      Maybe(vg.Rect),
	// Clips children to an SVG path in the group's space.
	clip_path: string,
	clip_rule: vg.Fill_Rule,
	// Gaussian blur of the composited children, standard deviation in the
	// group's units (SVG feGaussianBlur stdDeviation).
	blur:      f32,
	// The group's first child is a mask group (`mask_begin`): children show
	// where the mask is opaque.
	masked:    bool,
	// Set on the mask group itself; drawn only as a mask.
	is_mask:   bool,
	// The mask counts by alpha rather than luminance x alpha (SVG
	// mask-type="alpha"; luminance is the default).
	mask_alpha: bool,
	// A pattern tile's content; drawn only through its Pattern paint.
	is_pattern: bool,
	// SVG filter effects (primitives, merge inputs and values copied to
	// the arena).
	filter:    Maybe(vg.Filter),
	// Media names of the filter's image primitives (`Filter.images` is
	// filled from them when drawn).
	filter_images: []string,
	// CSS mix-blend-mode of the composited group onto what is under it.
	blend:     vg.Blend_Mode,
	// shape-rendering="crispEdges" for everything inside.
	crisp:     bool,
	// A box (in the group's space, after its transform) everything inside
	// should stay in: drawing is not clipped, `inspect` reports what spills
	// out (a card's text, a grid outgrowing its panel). `box_name` names it.
	box:       Maybe(vg.Rect),
	box_name:  string,
}

Rect :: struct {
	x, y, w, h: f32,
	// Corner radii; `ry` 0 means `rx` (SVG).
	rx, ry:     f32,
	fill:       Paint,
	fill_opacity: Maybe(f32),
	stroke:     Stroke,
	opacity:    Maybe(f32),
	// SVG shape-rendering="crispEdges": no antialiasing.
	crisp:   bool,
}

Circle :: struct {
	cx, cy, r: f32,
	fill:      Paint,
	fill_opacity: Maybe(f32),
	stroke:    Stroke,
	opacity:   Maybe(f32),
	// SVG shape-rendering="crispEdges": no antialiasing.
	crisp:   bool,
}

Ellipse :: struct {
	cx, cy, rx, ry: f32,
	fill:           Paint,
	fill_opacity:    Maybe(f32),
	stroke:         Stroke,
	opacity:        Maybe(f32),
	// SVG shape-rendering="crispEdges": no antialiasing.
	crisp:   bool,
}

Line :: struct {
	x1, y1, x2, y2: f32,
	stroke:         Stroke,
	opacity:        Maybe(f32),
	// SVG shape-rendering="crispEdges": no antialiasing.
	crisp:   bool,
}

// SVG path data (`M 0 0 L 10 0 ...`), the same syntax as `<path d=...>`,
// path data parsed once (`asset`), or a polyline / polygon through
// `points` (closed when `closed`).
Path :: struct {
	d:         string,
	asset:     ^Path_Asset,
	points:    []Vec2,
	closed:    bool,
	fill:      Paint,
	fill_opacity: Maybe(f32),
	fill_rule: vg.Fill_Rule,
	stroke:    Stroke,
	opacity:   Maybe(f32),
	// SVG shape-rendering="crispEdges": no antialiasing.
	crisp:   bool,
}

// SVG path data parsed once and drawn by reference, e.g. thousands of
// paths a script builds at load: every frame builder of a render shares
// one (read-only), and drawing copies it instead of parsing text.
Path_Asset :: struct {
	verbs:  []vg.Verb,
	coords: []vg.Vec2,
}

Text_Align :: enum u8 {
	Left,
	Center,
	Right,
}

// Where `y` sits on the first line (SVG dominant-baseline).
Text_Baseline :: enum u8 {
	Alphabetic,
	// Halfway up the x-height (SVG `middle`).
	Middle,
	// The middle of the em box (SVG `central`).
	Central,
	Hanging,
	// The top / bottom of the em box (`text-before-edge`, `text-after-edge`).
	Top,
	Bottom,
}

// Text with its first baseline at `y`. `size` is the em size in pixels,
// like CSS `font-size`; `weight` 0 means 400. "\n" starts a new line
// `line_height` em below (0 means 1.2). `spans` (SVG tspans) continue the
// text with their own style; their zero fields inherit the text's.
Text :: struct {
	text:           string,
	x, y:           f32,
	font:           string,
	size:           f32,
	weight:         int,
	italic:         bool,
	align:          Text_Align,
	baseline:       Text_Baseline,
	letter_spacing: f32,
	line_height:    f32,
	fill:           Paint,
	fill_opacity:   Maybe(f32),
	stroke:         Stroke,
	opacity:        Maybe(f32),
	spans:          []Text_Span,
}

Text_Span :: struct {
	text:           string,
	font:           string,
	size:           f32,
	weight:         int,
	italic:         Maybe(bool),
	letter_spacing: Maybe(f32),
	fill:           Paint,
	fill_opacity:   Maybe(f32),
	// Offset from where the span would start (SVG dx / dy).
	dx, dy:         f32,
}

// An image from the media directory, scaled to `w x h` (0 = natural size).
// An image from the media. `fit` follows SVG preserveAspectRatio: Contain
// (meet, the default), Cover (slice) or Fill (none).
Image :: struct {
	src:        string,
	x, y, w, h: f32,
	fit:        Image_Fit,
	// Where a contained/covered image sits in its box, 0..1 (0.5 = mid).
	align:      Maybe(Vec2),
	opacity:    Maybe(f32),
}

Node_Kind :: union {
	Group,
	Rect,
	Circle,
	Ellipse,
	Line,
	Path,
	Text,
	Image,
	Video_Clip,
	Shader,
	Svg,
	Lottie,
}

NO_NODE :: -1

Node :: struct {
	kind:        Node_Kind,
	first_child: i32,
	last_child:  i32,
	next:        i32,
}

// The node tree of one frame. Node 0 is the root group.
Tree :: struct {
	nodes:      [dynamic]Node,
	open:       [dynamic]i32,
	arena:      mem.Allocator,
	// Some node blends with what is under it: the frame draws into a layer.
	uses_blend: bool,
}

tree_reset :: proc(t: ^Tree, arena: mem.Allocator) {
	clear(&t.nodes)
	clear(&t.open)
	t.arena = arena
	t.uses_blend = false
	append(&t.nodes, Node{kind = Group{}, first_child = NO_NODE, last_child = NO_NODE, next = NO_NODE})
	append(&t.open, 0)
}

tree_destroy :: proc(t: ^Tree) {
	delete(t.nodes)
	delete(t.open)
	t^ = {}
}

@(private)
tree_add :: proc(t: ^Tree, kind: Node_Kind) -> i32 {
	idx := i32(len(t.nodes))
	append(&t.nodes, Node{kind = kind, first_child = NO_NODE, last_child = NO_NODE, next = NO_NODE})
	parent := &t.nodes[t.open[len(t.open) - 1]]
	if parent.last_child == NO_NODE {
		parent.first_child = idx
	} else {
		t.nodes[parent.last_child].next = idx
	}
	parent.last_child = idx
	return idx
}

// ---- builders ------------------------------------------------------------------------

// Opens a group; it closes at the end of the caller's block.
@(deferred_in = group_end)
group :: proc(ctx: ^Context, g: Group) {
	group_begin(ctx, g)
}

group_begin :: proc(ctx: ^Context, g: Group) {
	t := &ctx.tree
	g := g
	g.clip_path = strings.clone(g.clip_path, t.arena)
	g.box_name = strings.clone(g.box_name, t.arena)
	if fl, ok := g.filter.?; ok {
		prims := make([]vg.Filter_Primitive, len(fl.primitives), t.arena)
		copy(prims, fl.primitives)
		refs := make([]vg.Filter_Ref, len(fl.merge_refs), t.arena)
		copy(refs, fl.merge_refs)
		values := make([]f32, len(fl.values), t.arena)
		copy(values, fl.values)
		g.filter = vg.Filter {
			primitives = prims,
			merge_refs = refs,
			srgb       = fl.srgb,
			region     = fl.region,
			values     = values,
		}
		images := make([]string, len(g.filter_images), t.arena)
		for name, k in g.filter_images {
			images[k] = strings.clone(name, t.arena)
		}
		g.filter_images = images
	}
	if g.blend != .Normal {
		t.uses_blend = true
	}
	append(&t.open, tree_add(t, g))
}

// Opens a pattern tile's content: a hidden group under the root, drawn only
// through the Pattern paint that references it. Close with `group_end`.
// Returns the content node for `Pattern.content`.
pattern_begin :: proc(ctx: ^Context) -> i32 {
	t := &ctx.tree
	// Attach under the root, whatever is open.
	saved := t.open[len(t.open) - 1]
	t.open[len(t.open) - 1] = 0
	idx := tree_add(t, Group{is_pattern = true})
	t.open[len(t.open) - 1] = saved
	append(&t.open, idx)
	return idx
}

// Opens the mask of the group just opened with `masked = true`; close it
// with `group_end` before adding the group's content.
mask_begin :: proc(ctx: ^Context) {
	group_begin(ctx, Group{is_mask = true})
}

group_end :: proc(ctx: ^Context, _: Group = {}) {
	t := &ctx.tree
	if len(t.open) > 1 {
		pop(&t.open)
	}
}

rect :: proc(ctx: ^Context, r: Rect) {
	r := r
	r.fill = copy_paint(ctx, r.fill)
	r.stroke = copy_stroke(ctx, r.stroke)
	tree_add(&ctx.tree, r)
}

circle :: proc(ctx: ^Context, c: Circle) {
	c := c
	c.fill = copy_paint(ctx, c.fill)
	c.stroke = copy_stroke(ctx, c.stroke)
	tree_add(&ctx.tree, c)
}

ellipse :: proc(ctx: ^Context, e: Ellipse) {
	e := e
	e.fill = copy_paint(ctx, e.fill)
	e.stroke = copy_stroke(ctx, e.stroke)
	tree_add(&ctx.tree, e)
}

line :: proc(ctx: ^Context, l: Line) {
	l := l
	l.stroke = copy_stroke(ctx, l.stroke)
	tree_add(&ctx.tree, l)
}

path :: proc(ctx: ^Context, p: Path) {
	p := p
	p.d = strings.clone(p.d, ctx.tree.arena)
	if len(p.points) > 0 {
		pts := make([]Vec2, len(p.points), ctx.tree.arena)
		copy(pts, p.points)
		p.points = pts
	}
	p.fill = copy_paint(ctx, p.fill)
	p.stroke = copy_stroke(ctx, p.stroke)
	tree_add(&ctx.tree, p)
}

text :: proc(ctx: ^Context, t: Text) {
	t := t
	t.text = strings.clone(t.text, ctx.tree.arena)
	t.font = strings.clone(t.font, ctx.tree.arena)
	t.fill = copy_paint(ctx, t.fill)
	t.stroke = copy_stroke(ctx, t.stroke)
	if len(t.spans) > 0 {
		spans := make([]Text_Span, len(t.spans), ctx.tree.arena)
		for s, i in t.spans {
			spans[i] = s
			spans[i].text = strings.clone(s.text, ctx.tree.arena)
			spans[i].font = strings.clone(s.font, ctx.tree.arena)
			spans[i].fill = copy_paint(ctx, s.fill)
		}
		t.spans = spans
	}
	tree_add(&ctx.tree, t)
}

image :: proc(ctx: ^Context, i: Image) {
	i := i
	i.src = strings.clone(i.src, ctx.tree.arena)
	tree_add(&ctx.tree, i)
}

@(private)
copy_paint :: proc(ctx: ^Context, p: Paint) -> Paint {
	switch v in p {
	case Linear_Gradient:
		g := v
		g.stops = copy_stops(ctx, v.stops)
		return g
	case Radial_Gradient:
		g := v
		g.stops = copy_stops(ctx, v.stops)
		return g
	case Color, Pattern:
	}
	return p
}

@(private)
copy_stroke :: proc(ctx: ^Context, s: Stroke) -> Stroke {
	s := s
	s.paint = copy_paint(ctx, s.paint)
	if len(s.dash) > 0 {
		d := make([]f32, len(s.dash), ctx.tree.arena)
		copy(d, s.dash)
		s.dash = d
	}
	return s
}

@(private)
copy_stops :: proc(ctx: ^Context, stops: []vg.Gradient_Stop) -> []vg.Gradient_Stop {
	out := make([]vg.Gradient_Stop, len(stops), ctx.tree.arena)
	copy(out, stops)
	return out
}

// ---- colors -----------------------------------------------------------------------------

WHITE :: vg.WHITE
BLACK :: vg.BLACK
TRANSPARENT :: vg.TRANSPARENT

hex :: vg.hex_color
rgb :: vg.rgb
rgba :: vg.rgba
