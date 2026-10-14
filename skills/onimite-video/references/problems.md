# Problems and `--json` codes


Problems found while building or drawing frames have a stable `code`. Every drawn frame
gets the same checks, so `frame`, `strip`, `onion`, `inspect`, `render` and the preview's
problems panel agree on a frame. With `--json`, `frame` lists each frame's `diagnostics` as
`{severity, code, key, message, fields, source}` and `inspect` / `render` list `findings`
(most severe first) as `{severity, code, message, fields, first_frame, last_frame, ...,
source}`. What the load found (`unused_field`, `missing_font`, `physics_overlap`,
`physics_offscreen`, `physics_unsettled`, `tts_unavailable`, `tts_noncommercial`,
`tts_not_kept`, `missing_track`, `missing_track_time`, `unreadable_media`, `undecodable_media`) is printed as a
`warning:` line on stderr by every command, and `inspect`, `render` and the preview's panel
list it with `frames` 0 ("at load" in the text). `render` refuses to start while the load
found an error (`missing_track`, `missing_track_time`, `tts_unavailable`): error code `load_errors`. Only
`inspect` checks cues and the beat (`cue_*`, `off_beat`). `fields` holds the operands the message is made from, named like
its placeholders below (numbers as numbers, the rest as text); `key` is what groups a finding
across frames. `source` is the script line that drew the node a problem is about
(`scenes/race.lua:24`; `frame`, `strip` and `inspect` fill it, "" otherwise), and the text
output puts it before the message. Match on `code` and `fields`, not on the message text.

```json
{"severity": "warning", "code": "shader_uniform_count",
 "message": "shader glow.sksl: uniform `uTint` takes 4 values, got 3",
 "fields": {"count": 4, "got": 3, "name": "glow.sksl", "uniform": "uTint"},
 "source": "scenes/title.lua:31"}
```

| code | severity | message |
|------|----------|---------|
| `missing_image` | error | `Image "{name}" is not in the media provider` |
| `undecodable_image` | error | `Image "{name}" can not be decoded` |
| `missing_filter_image` | error | `Filter image "{name}" is not in the media provider` |
| `missing_svg` | error | `SVG "{name}" is not in the media provider` |
| `missing_lottie` | error | `Lottie "{name}" is not in the media provider` |
| `missing_video` | error | `no video {q:name} in the media` |
| `undecodable_video` | error | `video {q:name} can not be decoded: {video}` |
| `missing_audio` | error | `no audio {q:name} in the media` |
| `missing_track` | error | `{where}: the track plays {q:clip}, which is not in the media`: found at load; a track of `video{}` or `scene{}` names a sound the media lacks (missing, or a file that did not decode: see `undecodable_media`); `render` refuses to start (`load_errors`), the preview plays without it |
| `missing_track_time` | error | `{where}: the track is timed by the length of {q:clip}, which is not in the media`: found at load; a track's `start` or `stop` adds the length of a sound or video the media lacks; like `missing_track` |
| `missing_subtitles` | error | `no subtitles {q:name} in the media` |
| `missing_captions` | error | `no captions {q:name} in the media` |
| `missing_shader` | error | `Shader "{name}" is not in the media provider` |
| `missing_font` | warning | `No match for '"{name}"' font-family.` |
| `missing_glyph` | error | `No fonts with a glyph for "{glyph}" (U+{X4:codepoint}) in text "{text}"` |
| `unreadable_media` | warning | `can not read media file {q:name} ({reason})`: found when the media folder loads; the rest still loads |
| `undecodable_media` | warning | `media file {q:name} can not be decoded as {what}` (audio, a font, an image, SVG, Lottie, subtitles): found when the media folder loads; a `.json` file that is neither Lottie nor captions is the script's own data, not a problem |
| `svg_markup` | error | `SVG markup does not parse ({svg})` |
| `svg_warning` | warning | `SVG {q:name}: {warning}` |
| `svg_missing_id` | warning | `SVG {q:name} has no element with id {q:id}` |
| `lottie_data` | error | `Lottie data does not parse ({lottie})` |
| `lottie_warning` | warning | `Lottie {q:name}: {warning}` |
| `lottie_missing_layer` | warning | `Lottie {q:name} has no layer named {q:layer}` |
| `shader_compile` | error | `shader {at}: {error}` |
| `shader_zero_size` | warning | `shader {name} with zero size at ({x}, {y}) is skipped` |
| `shader_no_channel` | warning | `` shader {name} samples no channel `{channel}` `` |
| `shader_no_child` | warning | `` shader {name} has no `uniform shader {channel}` `` |
| `shader_undeclared_uniform` | warning | `` shader {name}: uniform `{uniform}` is not declared `` |
| `shader_uniform_count` | warning | `` shader {name}: uniform `{uniform}` takes {count} values, got {got} `` |
| `shader_unset_uniform` | warning | `` shader {name}: uniform `{uniform}` is not set `` |
| `shader_unbound_channel` | warning | `` shader {name}: `{channel}` has no image bound `` |
| `shader_pass_input` | warning | `` shader {name}: `{uniform}` binds an input; a program of passes binds inputs in its passes `` |
| `shader_pass_unbound` | warning | `` shader {name}: {pass}'s `{channel}` has nothing bound `` |
| `shader_load` | error | `shader {name} can not be loaded by the renderer: {gpu}` |
| `shader_run` | error | `shader {name}: {gpu}` |
| `shader_image` | error | `shader image: {gpu}` |
| `shader_buffer` | error | `shader buffer {width}x{height}: {gpu}` |
| `image_upload` | error | `image {q:name} could not be uploaded: {gpu}` |
| `video_frame_image` | error | `video frame image: {gpu}` |
| `rect_zero_size` | warning | `rect with zero size at ({x}, {y}) is skipped` |
| `circle_zero_radius` | warning | `circle with zero radius at ({x}, {y}) is skipped` |
| `ellipse_zero_radius` | warning | `ellipse with zero radius at ({x}, {y}) is skipped` |
| `invalid_path` | error | `invalid path data {q:value}` |
| `invalid_clip_path` | error | `invalid clip path {q:value}` |
| `text_clipped` | warning | `text {q:text} is cut off by the canvas edge (x={r:x} y={r:y} w={r:w} h={r:h})` |
| `text_off_canvas` | info | `text {q:text} is outside the canvas (x={r:x} y={r:y} w={r:w} h={r:h})` |
| `nan_transform` | error | `node "{kind}#{index}" has a NaN or infinite transform` |
| `empty_frame` | warning | `frame is empty` |
| `script_error` | error | `{message}` |
| `invalid_value` | error | `invalid {kind} {q:value} (want {want})` |
| `unused_field` | warning | `` {where}: `{field}` is not used (did you mean `{suggestion}`?) `` (no suggestion when none is close) |
| `animate_no_stop` | warning | `` {where}: animate's last key has no stop, so it jumps to its `to` at {start}s `` ... |
| `cue_drift` | warning | `cue {q:cue}: {what}: {ds:drift}s off {ref}` |
| `cue_alone` | warning | `cue {q:cue}: only {what} has this id, nothing meets it` |
| `outside_box` | warning | `{node} spills {r:w}px out of box {q:box}` |
| `text_overlap` | warning | `text {q:text} overlaps text {q:other} ({r:w}x{r:h}px)`: two readable texts (opacity 0.3 or more) of one scene whose inked glyphs cover each other by a third of the smaller each way; not a text and its copy (a shadow), not single characters, not inside blurred or filtered groups or shader inputs |
| `cue_no_hit` | warning | `cue {q:cue}: no sound of {ref} starts within 30 ms of {s:time}s (nearest: {what})` |
| `off_beat` | warning | `{where}: {count} sounds start off the music's beat, the loudest {q:clip} {ds:drift}s off at {s:time}s (the beat: {s:period}s; hits belong on the beat or half-beat)`: sounds (not on the `voice` bus, not `voice = true`) against the tracks on the `music` bus, more than 30 ms off the half-beat grid measured around each (audio.md, "Checking without listening"); one per placing line |
| `physics_overlap` | warning | `{where}: physics body {q:body} starts {r:depth}px inside {q:with} at {s:time}s, so they fly apart (move it or give it room)`: found when `physics{}` simulates (at load), more than 3 px deep at the body's first step |
| `physics_offscreen` | warning | `{where}: physics body {q:body} leaves the canvas at {s:time}s and does not come back`: a dynamic body seen on the canvas and off it at the end; `leaves = true` on the body when that is the point |
| `tts_unavailable` | error | `{where}: say {q:line} can not be spoken ({reason}): it is silent and its word times are estimates`: found at load; the line can't be synthesized (ottis's download failed, ONNX Runtime or a model didn't load, an unknown voice; `say()` is tested on Linux x86_64 and macOS Apple Silicon, untested on Windows x86_64). The script loads with the line silent; `render` refuses to start (error code `load_errors`) |
| `tts_not_kept` | warning | `{where}: say {q:line} was spoken but could not be kept in the store ({reason}): every run speaks it again`: found at load; the line plays, but the store under the user data folder could not be written |
| `tts_noncommercial` | warning | `{where}: say {q:line} uses voice {q:voice}, whose recording is licensed for non-commercial use only`: `cosette` and `jean` |
| `physics_unsettled` | warning | `{where}: physics body {q:body} is still moving at {s:time}s, the end of the simulation: later frames hold it there mid-motion (simulate longer)`: a frame samples (`physics_at`) past the end while the body still moved there |

`{q:...}` is the value quoted, `{r:...}` rounded, `{s:...}` seconds to the millisecond,
`{ds:...}` the same with a sign, `{X4:...}` four hex digits; `{video}` is
the decoder's reason (`no video track`, or odecs' error and detail), `{gpu}`, `{svg}` and
`{lottie}` the renderer's or parser's error name, `{where}` the script line (`video.lua:12`), `{error}` and `{at}` the shader compiler's
message and `name:line:col` (`name: pass:line:col` in a program of passes: `trail.sksl: blur:3:9`,
`image.glsl: Buffer A:3:9`, `Common` for the common source); `{warning}` is
the SVG or Lottie parser's own note.

A command that fails prints `error: message` on stderr, or with `--json` the document
`{"error": "message", "code": "..."}` (exit code 1). Its codes: `props_read`,
`no_media_dir`, `script` (the script did not load: a Lua error, a missing `video{}`, no
duration, bad props), `renderer`, `spec_unknown_scene`, `spec_unknown_name` (neither a scene nor a cue; the
message lists both), `spec_no_scenes`, `spec_ambiguous`, `spec_past_scene`,
`spec_out_of_range` (the message names the valid frames, `frames 0..N-1`), `spec_invalid`,
`create_dir`, `write`, `png_many_frames` (`frame -o x.png` with more than one frame), `command_needs` (a command without an argument it needs, e.g. an MCP `onion` with an empty `range`; the message names it), `command_domain` (a command where it can not run, e.g. a preview command with no preview window open), `no_sheet_frames`, `snapshot_size` (`snapshot`: an approved PNG has
another size than the frame, e.g. checked at another `--scale`; the message gives both
sizes; `--update` accepts the new size), `encoder` (the MP4 writer:
odd dimensions, the file, a frame, the GPU conversion), `read_back` (a frame could not be
read back from the GPU), `batch_read`,
`batch_json`, `batch_not_array`, `batch_not_object`, `batch_csv`, `batch_no_header`,
`batch_rows`, `output_no_field`, `output_not_scalar`, `no_track` (`--track` names no track),
`load_errors` (`render`: the script's load found errors, such as a `say()` line that could
not be synthesized or a track whose sound is missing; the message gives the count and the
first), `probe` (`probe`: a file odecs can not read), `window` and `window_drawing` (`preview`: the
window, its GPU device or its drawing could not be set up), `no_path` (`show`: nothing at
that path; the message lists the paths there are), and `update`'s: `update_dev` (a source
build), `update_platform` (no release for this platform), `update_fetch`, `update_checksum`
(the archive does not match `SHA256SUMS`), `update_unpack`, `update_broken` (the new binary
does not run here), `update_install`. A `--json` document that can not be written is
`{"error": ..., "code": "output"}`; an MCP tool call with an argument the tool does not
take (or a bad value) is `usage`. A clip whose `audio_add(name, fn)`
function fails fails the command as `script`, the message naming the clip
(`audio_add("name"): the clip's function failed: ...`); the preview lists it as a
`script_error`. A failing `--batch` row keeps the
batch going and reports its message in the row's `error`.
