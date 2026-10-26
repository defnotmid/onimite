# Problems and `--json` codes


Problems found while building or drawing frames have a stable `code`. Every drawn frame
gets the same checks, so `frame`, `strip`, `onion`, `inspect`, `render` and the preview's
problems panel agree on a frame. With `--json`, `frame` lists each frame's `diagnostics` as
`{severity, code, key, message, fields, source}` and `inspect` / `render` list `findings`
(most severe first) as `{severity, code, message, fields, first_frame, last_frame, ...,
source}`. What the load found (`unused_field`, `missing_font`, `physics_overlap`,
`physics_offscreen`, `physics_unsettled`, `physics_outline_gaps`, `physics3d_overlap`, `physics3d_offscreen`, `tts_unavailable`, `tts_noncommercial`,
`tts_not_kept`, `song_finding`, `effect_finding`, `missing_track`, `missing_track_time`, `unreadable_media`, `undecodable_media`) is printed as a
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
| `undecodable_video` | error | `video {q:name} can not be decoded: {video}`: no video track, a track no decoder takes (found when the media loads; convert it with ffmpeg, see media.md), or a decode that failed partway |
| `missing_audio` | error | `no audio {q:name} in the media` |
| `missing_track` | error | `{where}: the track plays {q:clip}, which is not in the media`: found at load; a track of `video{}` or `scene{}` names a sound the media lacks (missing, or a file that did not decode: see `undecodable_media`); `render` refuses to start (`load_errors`), the preview plays without it |
| `missing_track_time` | error | `{where}: the track is timed by the length of {q:clip}, which is not in the media`: found at load; a track's `start` or `stop` adds the length of a sound or video the media lacks; like `missing_track` |
| `missing_subtitles` | error | `no subtitles {q:name} in the media` |
| `missing_captions` | error | `no captions {q:name} in the media` |
| `missing_shader` | error | `Shader "{name}" is not in the media provider` |
| `missing_font` | warning | `No match for '"{name}"' font-family.` |
| `missing_glyph` | error | `No fonts with a glyph for "{glyph}" (U+{X4:codepoint}) in text "{text}"` |
| `unreadable_media` | warning | `can not read media file {q:name} ({reason})`: found when the media folder loads; the rest still loads |
| `undecodable_media` | warning | `media file {q:name} can not be decoded as {what}` (audio, a font, an image, SVG, Lottie, subtitles, a 3D model: a `.glb`, `.gltf`, `.3mf`, `.obj`, `.usdz` or `.usdc` that o3d rejects (malformed, failing the format's rules, or past a limit that stops the read), requires an unsupported extension in `extensionsRequired`, or whose buffers or images beside it are missing): found when the media folder loads; a `.json` file that is neither Lottie nor captions is the script's own data, not a problem |
| `svg_markup` | error | `SVG markup does not parse ({svg})` |
| `svg_warning` | warning | `SVG {q:name}: {warning}` |
| `svg_missing_id` | warning | `SVG {q:name} has no element with id {q:id}` |
| `lottie_data` | error | `Lottie data does not parse ({lottie})` |
| `lottie_warning` | warning | `Lottie {q:name}: {warning}` |
| `lottie_missing_layer` | warning | `Lottie {q:name} has no layer named {q:layer}` |
| `shader_compile` | error | `shader {at}: {error}` (a `shader{}` layer or a `view3d` `ShaderMaterial`; a failed shader skips its draw) |
| `shader_zero_size` | warning | `shader {name} with zero size at ({x}, {y}) is skipped` |
| `shader_no_channel` | warning | `` shader {name} samples no channel `{channel}` `` |
| `shader_no_child` | warning | `` shader {name} has no `uniform shader {channel}` `` |
| `shader_undeclared_uniform` | warning | `` shader {name}: uniform `{uniform}` is not declared `` (`{name}` is `"ShaderMaterial"` for a `view3d` `ShaderMaterial`) |
| `shader_uniform_count` | warning | `` shader {name}: uniform `{uniform}` takes {count} values, got {got} `` |
| `shader_unset_uniform` | warning | `` shader {name}: uniform `{uniform}` is not set `` (`{name}` is `"ShaderMaterial"` for a `view3d` `ShaderMaterial`) |
| `shader_unbound_channel` | warning | `` shader {name}: `{channel}` has no image bound `` |
| `shader_pass_input` | warning | `` shader {name}: `{uniform}` binds an input; a program of passes binds inputs in its passes `` |
| `shader_depth_of` | error | ``shader {name}: `{channel}` takes the depth of {q:ref}, which is not a group input of this shader``: `depth_of` names an input that isn't a group (a function of nodes) of the same shader; the channel reads nothing |
| `shader_pass_unbound` | warning | `` shader {name}: {pass}'s `{channel}` has nothing bound `` |
| `shader_frame_rate` | warning | `shader {name}: {pass} reads its own last frame but not iTimeDelta, so it looks different at another fps (...)`: a feedback pass whose fade, drift or decay is a fixed amount a frame; write each step as a rate a second times `iTimeDelta` (`pow(keep_per_second, iTimeDelta)` for a fade, `speed * iTimeDelta` for a drift, `sqrt(iTimeDelta)` scaling for a blur's spread) |
| `shader_load` | error | `shader {name} can not be loaded by the renderer: {gpu}` |
| `shader_run` | error | `shader {name}: {gpu}` |
| `shader_image` | error | `shader image: {gpu}` |
| `shader_buffer` | error | `shader buffer {width}x{height}: {gpu}` |
| `image_upload` | error | `image {q:name} could not be uploaded: {gpu}` |
| `video_frame_image` | error | `video frame image: {gpu}` |
| `missing_model` | error | `no model {q:name} in the media`: a `view3d` model's `src` (`.glb`, `.gltf`, `.3mf`, `.obj`, `.usdz`, `.usdc` files of the media folder); a texture, `environment` or `background` image the media lacks is `missing_image` |
| `missing_animation` | error | `model {q:name} has no animation {q:animation}`: a model's `animation` names none of its clips (or its index is past them); the model is drawn in its rest pose |
| `missing_model_part` | error | `model {q:name} has no {what} {q:ref}`: a model's `nodes` / `materials`, or an `attach.node`, names a node or material the model lacks (`show video.lua media/<model>` lists them); that change is ignored, or what is attached draws unattached |
| `attach_target` | error | `{name}: attach.model {index} is not a model drawn before it`: `attach.model` is past the view's models, or a model attaches to itself or a later one; it draws unattached |
| `missing_morph_target` | error | `model {q:name} has no morph target {q:target}`: a model's `morphs` names a target the model lacks (or an index outside `1..N`); that override is ignored |
| `model_warning` | warning | `model {q:name}: {warning}`: o3d read or draws the model only in part: a limit was reached (`limit reached: ...; the file is not read` or `; the rest is skipped`), one of its images could not be decoded (that texture is left off), a material feature is not drawn (an extension such as `KHR_materials_iridescence`, a USD clearcoat), or a USD file holds what is not read (references to other files, skeletons, lights, cameras) or is read leniently (normals declared uniform with faceVarying's count) |
| `view3d_zero_size` | warning | `view3d with zero size at ({x}, {y}) is skipped` |
| `extrude_folded` | warning | `an ExtrudeGeometry's bevel folds {r:w} of its outline's contours over themselves: its faces get holes and its walls turn inside out (keep an inward bevel_offset, or bevel_size around a hole, under half the outline's thinnest part)`: an inward bevel thicker than half of a stroke, a pixel or a gap turns that part inside out (three.js does the same); scale the bevel to the outline's thinnest part |
| `geometry_growth` | warning | ``{kind} made again with other parameters frame after frame: each new set of geometry parameters makes and keeps a mesh, so change a size through the mesh's `scale`, not its geometry's parameters``: a `view3d` mesh's geometry parameters (`radius`, `width`, segment counts) change from frame to frame, so every frame makes a mesh that stays for the whole render (shapes of fixed parameters that first appear later in a scene are not growth); `{kind}` is the three.js type (`SphereGeometry`). Animate `scale` (and `position`, `rotation`) instead (3d.md) |
| `view3d_render` | error | `view3d could not be drawn: {o3d}`: the 3D renderer failed (`{o3d}`: `Device`, no GPU device that can draw it; `Out_Of_Memory`; `Shader`) |
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
| `voice_level` | warning | `{where}: voice line {q:clip} sits {1:w} LU {reason} the median of the video's {count} voice lines: its track's gain_db {1s:h} levels it with them (or check its voice's own level)`: `inspect` measures each voice track (a `say` line, or a track on the `voice` bus) as it plays, with its gain, and names one more than 4 LU from the median of them all (a recording at its own level, or a line given its own `gain_db`; `say` makes every line at -23 LUFS); one per line |
| `physics_overlap` | warning | `{where}: physics body {q:body} starts {r:depth}px inside {q:with} at {s:time}s, so they fly apart (move it or give it room)`: found when `physics{}` simulates (at load), more than 3 px deep at the body's first step |
| `physics_outline_gaps` | warning | `{where}: physics body {q:body} collides with only {r:w}% of its outline: pieces too thin or small for Box2D (under 0.5 px across) are left out, and other bodies pass through there (draw the outline larger or with thicker parts)`: found when `physics{}` builds an `outline` body: the convex pieces Box2D can't take (hairlines, specks) leave holes other bodies sink into |
| `physics_offscreen` | warning | `{where}: physics body {q:body} leaves the canvas at {s:time}s and does not come back`: a dynamic body seen on the canvas and off it at the end; `leaves = true` on the body when that is the point |
| `tts_unavailable` | error | `{where}: say {q:line} can not be spoken ({reason}): it is silent and its word times are estimates`: found at load; the line can't be synthesized (ottis's download failed, ONNX Runtime or a model didn't load, an unknown voice; `say()` is tested on Linux x86_64 and macOS Apple Silicon, untested on Windows x86_64). The script loads with the line silent; `render` refuses to start (error code `load_errors`) |
| `tts_not_kept` | warning | `{where}: say {q:line} was spoken but could not be kept in the store ({reason}): every run speaks it again`: found at load; the line plays, but the store under the user data folder could not be written |
| `song_finding` | as odawg rates it | `{where}: song {q:clip}: {reason}`: found at load (a misspelled key `unknown_key`, a `bad_value`, a timing that can't be met `start_unreachable` / `duration_unreachable` with each section's least length, `no_events` from `pulse`/`hits`/`events` reading nothing, a sample set that can't be fetched `asset_unavailable` (also once a song's samples load: files its notes reach that aren't pinned play silent until `onimite audio pin`; `inspect`, `audio parts` and `audio analyze` report it, the preview once its sounds are in), a note no layer, region or pad answers `no_region`, a pitch outside MIDI `note_range`, an effect that is neither built in nor a row the song names `unknown_effect`, an effect row with an envelope, oscillator or sample in it `effect_reads_note`, an SFZ opcode that doesn't play `unsupported_opcode` or isn't SFZ's `unknown_opcode` (with its use count and the file and line of the first), an SFZ no region of plays at its CCs `sfz_silent`, an SFZ still played through `{ "Sampler", set = ... }` `sfz_instrument`, a sample its sources haven't pinned `not_pinned`, a set whose licence isn't allowed `licence_not_allowed`, a bus routed into itself `routing_loop`, an option that reaches nothing in its row `unknown_option_target`, a control named like a node's field `control_shadows_field`) or by `inspect` rendering the song alone (a part outside its `role`'s band of LU under the mix `role_balance`, naming the `gain_db` change or a per-section lane; a part with notes in the range that makes no sound `silent_part`; a part without a role more than 15 LU under the mix in every section it has notes in `buried_part`, naming the `gain_db` raise that puts it 12 LU under where it plays loudest; a song on four of a generator's defaults `default_song`; `clipping`, `true_peak`); the code is at the end of the reason. Errors make `render` refuse (`load_errors`) |
| `effect_finding` | as odawg rates it | `{where}: audio track {q:clip}: {reason}`: found at load, reading a track's `effects` as the mix will (`bad_value` for an effect that isn't one, `unknown_key` for a misspelled setting); the code is at the end of the reason. Errors make `render` refuse (`load_errors`) |
| `tts_noncommercial` | warning | `{where}: say {q:line} uses voice {q:voice}, whose recording is licensed for non-commercial use only`: `cosette` and `jean` |
| `physics_unsettled` | warning | `{where}: physics body {q:body} is still moving at {s:time}s, the end of the simulation: later frames hold it there mid-motion (simulate longer)`: a frame samples (`physics_at`) past the end while the body still moved there |
| `physics3d_overlap` | warning | `{where}: physics3d body {q:body} starts {r:depth} cm inside {q:with} at {s:time}s, so they fly apart (move it or give it room)`: found when `physics3d{}` simulates (at load), more than 3 cm deep at the body's first step |
| `physics3d_offscreen` | warning | `{where}: physics3d body {q:body} leaves the world's bounds at {s:time}s and does not come back (widen the simulation's bounds, or leaves = true on the body)`: a dynamic body inside `bounds` (default ±50 m) and outside at the end |

`{q:...}` is the value quoted, `{r:...}` rounded, `{s:...}` seconds to the millisecond,
`{ds:...}` the same with a sign, `{X4:...}` four hex digits; `{video}` is
the decoder's reason (`no video track`, or odecs' error and detail), `{gpu}`, `{svg}` and
`{lottie}` the renderer's or parser's error name, `{o3d}` the 3D renderer's, `{where}` the script line (`video.lua:12`), `{error}` and `{at}` the shader compiler's
message and `name:line:col` (`name: pass:line:col` in a program of passes: `trail.sksl: blur:3:9`,
`image.glsl: Buffer A:3:9`, `Common` for the common source; `Vertex:line:col` or `Fragment:line:col` in a `view3d` `ShaderMaterial`); `{warning}` is
the SVG or Lottie parser's own note.

A command that fails prints `error: message` on stderr, or with `--json` the document
`{"error": "message", "code": "..."}` (exit code 1). Its codes: `props_read`,
`no_media_dir`, `script` (the script did not load: a Lua error, a missing `video{}`, no
duration, bad props), `renderer`, `spec_unknown_scene`, `spec_unknown_name` (neither a scene nor a cue; the
message lists both), `spec_no_scenes`, `spec_ambiguous`, `spec_past_scene`,
`spec_out_of_range` (the message names the valid frames, `frames 0..N-1`), `spec_invalid`,
`create_dir`, `write`, `parts_read` (`audio parts --against`: the file is not an earlier `--json` of it), `png_many_frames` (`frame -o x.png` with more than one frame), `command_needs` (a command without an argument it needs, e.g. an MCP `onion` with an empty `range`; the message names it), `command_domain` (a command where it can not run, e.g. a preview command with no preview window open), `no_sheet_frames`, `snapshot_size` (`snapshot`: an approved PNG has
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
