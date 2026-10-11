# Pip, the mascot: a 32x32 pixel-art mite, a tiny firecracker with a lit
# fuse. Writes an SVG whose parts are groups a script shows or hides by id
# (svg{ overrides = { eyes_closed = { visible = true } } }):
#
#   body         outline, fill, shade, highlight, cheeks, feet, fuse (always on)
#   eyes_open    big eyes with two shines (on)     eyes_closed  a blink, sleepy
#   eyes_o       round surprised eyes
#   mouth_smile  (on)                              mouth_o      a little "o"
#   spark_a      a four-point twinkle (on)         spark_b      the twinkle turned
#   spark_boom   a big burst
#
#   python3 tools/mascot/pip.py examples/common/pip.svg   (also prints the body)
#
# Pip is also the project's logo: write it to assets/logo.svg as well, and
# render assets/logo.png (256 px) and assets/logo_32x32.png from it, e.g.
#   rsvg-convert -w 256 -h 256 assets/logo.svg -o assets/logo.png
import sys

W = H = 32
PAL = {
  'O': '#2b1b2e', 'B': '#ff5a4e', 'D': '#d63b44', 'H': '#ffa38f', 'W': '#ffffff', 'E': '#1b1220',
  'C': '#ff9db4', 'M': '#7a1f2e', 'F': '#c9a26b', 'f': '#8a6a3c', 'S': '#ffe14d', 's': '#ff9f1c',
}

def grid():
    return [['.'] * W for _ in range(H)]

def put(g, x, y, c):
    if 0 <= x < W and 0 <= y < H:
        g[y][x] = c

# ---- the body ------------------------------------------------------------------
body = grid()
cx, cy, rx, ry = 15.5, 18.0, 11.0, 8.6
inside = lambda x, y: ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1
for lx in (7, 11, 18, 22): # four little feet peeking out
    for y in (25, 26):
        put(body, lx, y, 'D'); put(body, lx + 1, y, 'D')
    for (x, y) in ((lx, 27), (lx + 1, 27), (lx - 1, 25), (lx - 1, 26), (lx + 2, 25), (lx + 2, 26)):
        put(body, x, y, 'O')
for y in range(H):
    for x in range(W):
        if inside(x, y):
            u, v = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
            # a soft rim of shade along the bottom right edge
            put(body, x, y, 'D' if u * u + v * v > 0.62 and u * 0.45 + v * 0.9 > 0.35 else 'B')
for (x, y) in [(8, 13), (9, 13), (10, 13), (8, 14), (9, 14), (7, 15), (8, 15), (12, 12), (13, 12)]:
    put(body, x, y, 'H')
for y in range(H):
    for x in range(W):
        if body[y][x] == '.' and any(0 <= x + dx < W and 0 <= y + dy < H and body[y + dy][x + dx] in 'BDH'
                                     for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            put(body, x, y, 'O')
for (x, y) in [(7, 20), (8, 20), (22, 20), (23, 20)]:
    put(body, x, y, 'C')
for i, (x, y) in enumerate([(15, 9), (15, 8), (16, 7), (16, 6), (17, 5), (18, 5), (19, 4)]):
    put(body, x, y, 'F')
    if i < 3:
        put(body, x + 1, y, 'f')

# ---- faces ----------------------------------------------------------------------
eyes_open, eyes_closed, eyes_o = grid(), grid(), grid()
for ex in (10, 18):
    for y in range(16, 20):
        for x in range(ex, ex + 3):
            put(eyes_open, x, y, 'E')
    for (x, y) in ((ex, 16), (ex + 1, 16), (ex, 17), (ex + 2, 19)):
        put(eyes_open, x, y, 'W')
    # a happy closed eye: a little arch
    for (x, y) in ((ex, 18), (ex + 1, 17), (ex + 2, 18)):
        put(eyes_closed, x, y, 'E')
    # surprised: round, wide open, one big shine
    for y in range(15, 20):
        for x in range(ex - 1 if y in (16, 17, 18) else ex, ex + 4 if y in (16, 17, 18) else ex + 3):
            put(eyes_o, x, y, 'E')
    put(eyes_o, ex, 16, 'W'); put(eyes_o, ex + 1, 16, 'W'); put(eyes_o, ex, 17, 'W')
mouth_smile, mouth_o = grid(), grid()
for (x, y) in [(14, 21), (15, 22), (16, 22), (17, 21)]:
    put(mouth_smile, x, y, 'M')
for (x, y) in [(15, 21), (16, 21), (15, 22), (16, 22)]:
    put(mouth_o, x, y, 'M')

# ---- sparks ----------------------------------------------------------------------
spark_a, spark_b, spark_boom = grid(), grid(), grid()
sx, sy = 21, 3
put(spark_a, sx, sy, 'W')
for (x, y) in ((sx + 1, sy), (sx - 1, sy), (sx, sy + 1), (sx, sy - 1)):
    put(spark_a, x, y, 'S')
for (x, y) in ((sx + 2, sy), (sx, sy - 2), (sx, sy + 2)):
    put(spark_a, x, y, 's')
put(spark_b, sx, sy, 'W')
for (x, y) in ((sx + 1, sy + 1), (sx - 1, sy - 1), (sx + 1, sy - 1), (sx - 1, sy + 1)):
    put(spark_b, x, y, 'S')
for (x, y) in ((sx + 2, sy - 2), (sx - 2, sy + 2)):
    put(spark_b, x, y, 's')
for dx in range(-3, 4):
    for dy in range(-3, 4):
        d = abs(dx) + abs(dy)
        if (dx == 0 or dy == 0 or abs(dx) == abs(dy)) and d <= 4:
            put(spark_boom, sx + dx, sy + dy, 'W' if d == 0 else 'S' if d <= 2 else 's')

LAYERS = [('body', body, True), ('eyes_open', eyes_open, True), ('eyes_closed', eyes_closed, False),
          ('eyes_o', eyes_o, False), ('mouth_smile', mouth_smile, True), ('mouth_o', mouth_o, False),
          ('spark_a', spark_a, True), ('spark_b', spark_b, False), ('spark_boom', spark_boom, False)]

out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W * 8}" height="{H * 8}" shape-rendering="crispEdges">']
for name, g, on in LAYERS:
    rects = ''.join(f'<rect x="{x}" y="{y}" width="1" height="1" fill="{PAL[g[y][x]]}"/>'
                    for y in range(H) for x in range(W) if g[y][x] != '.')
    out.append(f'<g id="{name}"{"" if on else " display=\"none\""}>{rects}</g>')
out.append('</svg>\n')
open(sys.argv[1], 'w').write('\n'.join(out))
print('\n'.join(''.join(r) for r in body))
