package onimite_app

import "core:encoding/csv"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import om "../onimite"
import script "../script"

// Batch rendering (Remotion's input props + renderMedia, fframes' videos per
// parameter set): one render per row of a JSON or CSV file, the row merged
// into the script's `props`. The media loads once; the script reloads per
// row. A failing row is reported and the batch goes on.

Batch_Row_Result :: struct {
	// 1-based, as in `{index}` and --rows.
	row:    int                   `json:"row"`,
	output: string                `json:"output"`,
	ok:     bool                  `json:"ok"`,
	error:  Maybe(string)         `json:"error"`,
	render: Maybe(Render_Result)  `json:"render"`,
}

Batch_Result :: struct {
	rows:            []Batch_Row_Result `json:"rows"`,
	rendered:        int                `json:"rendered"`,
	failed:          int                `json:"failed"`,
	elapsed_seconds: f32                `json:"elapsed_seconds"`,
}

BATCH_DEFAULT_OUTPUT :: "out/{index}.mp4"

@(private)
batch_render :: proc(app: ^App_State, regs: Command_Regs) -> Error {
	began := time.tick_now()
	// Everything the batch keeps lives here: renders free the temp
	// allocator after every frame.
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	ba := virtual.arena_allocator(&arena)

	data, err := os.read_entire_file(regs.props, ba)
	if err != nil {
		return fail(app, {code = .Batch_Read, path = regs.props, os = err})
	}
	why: Failure
	rows, rows_err := batch_rows(regs.props, string(data), ba, &why)
	if rows_err != nil {
		return fail(app, why)
	}
	first := max(regs.rows[0], 1)
	last := regs.rows[1] if regs.rows[1] > 0 else len(rows)
	if first > last || last > len(rows) {
		return fail(app, {code = .Batch_Rows, path = regs.props, n = first, m = last, count = len(rows)})
	}

	results := make([]Batch_Row_Result, last - first + 1, ba)
	failed := 0
	for &res, k in results {
		res.row = first + k
		row := rows[res.row - 1]
		// A failing row leaves its failure in `app.failure` until its
		// message is made here.
		out, row_err := batch_output(regs.path, row, res.row, ba, &why)
		if row_err != nil {
			fail(app, why)
		} else {
			res.output = out
			fmt.eprintfln("[%d/%d] row %d -> %s", k + 1, len(results), res.row, out)
			text, _ := json.marshal(row, {}, ba)
			row_err = script_reload(app, string(text))
			if row_err == nil {
				row_regs := regs
				row_regs.path = out
				r: Render_Result
				r, row_err = video_render_to(app, row_regs, ba)
				if row_err == nil {
					res.render = r
					res.ok = true
				}
			}
		}
		if row_err != nil {
			message := failure_message(app.failure, ba)
			res.error = message
			failed += 1
			fmt.eprintfln("error: row %d: %s", res.row, message)
		}
		failure_clear(app)
	}
	if failed > 0 {
		app.exit_code = 1
	}

	summary := Batch_Result{results, len(results) - failed, failed, f32(time.duration_seconds(time.tick_since(began)))}
	b := strings.builder_make(context.temp_allocator)
	for res in results {
		if r, ok := res.render.?; ok {
			fmt.sbprintf(&b, "row %d %s\n", res.row, render_text(r))
		} else {
			fmt.sbprintf(&b, "row %d failed: %s\n", res.row, res.error.? or_else "")
		}
	}
	fmt.sbprintf(&b, "%d row%s: %d rendered, %d failed in %.1fs", len(results), "" if len(results) == 1 else "s", summary.rendered, failed, summary.elapsed_seconds)
	emit(app, summary, strings.to_string(b))
	return nil
}

// The rows of a batch file: a .csv (header row, then rows) or a JSON array
// of objects. On failure `why` says what is wrong.
batch_rows :: proc(path, text: string, allocator: mem.Allocator, why: ^Failure) -> (rows: []json.Object, err: Error) {
	if strings.equal_fold(filepath.ext(path), ".csv") {
		return batch_rows_csv(path, text, allocator, why)
	}
	v, jerr := json.parse_string(text, parse_integers = true, allocator = allocator)
	if jerr != nil {
		why^ = {code = .Batch_Json, path = path, json = jerr}
		return nil, why.code
	}
	list, is_array := v.(json.Array)
	if !is_array {
		why^ = {code = .Batch_Not_Array, path = path}
		return nil, why.code
	}
	out := make([]json.Object, len(list), allocator)
	for item, i in list {
		obj, is_object := item.(json.Object)
		if !is_object {
			why^ = {code = .Batch_Not_Object, path = path, n = i + 1}
			return nil, why.code
		}
		out[i] = obj
	}
	return out, nil
}

// CSV rows as objects keyed by the header row. Fields are strings, or
// numbers when they read as JSON numbers (`script.scalar_value`).
batch_rows_csv :: proc(path, text: string, allocator: mem.Allocator, why: ^Failure) -> (rows: []json.Object, err: Error) {
	records, cerr := csv.read_all_from_string(strings.trim_prefix(text, "\xef\xbb\xbf"), allocator, allocator)
	if cerr != nil {
		why^ = {code = .Batch_Csv, path = path, csv = cerr}
		return nil, why.code
	}
	if len(records) == 0 {
		why^ = {code = .Batch_No_Header, path = path}
		return nil, why.code
	}
	header := records[0]
	out := make([dynamic]json.Object, allocator)
	for record in records[1:] {
		if len(record) == 1 && strings.trim_space(record[0]) == "" {
			continue
		}
		obj := make(json.Object, len(header), allocator)
		for name, i in header {
			obj[strings.trim_space(name)] = script.scalar_value(record[i]) if i < len(record) else json.String("")
		}
		append(&out, obj)
	}
	return out[:], nil
}

// The output path of row `index` (1-based): `{field}` takes the row's value
// (`/` becomes `_`), `{index}` the row number unless the row has that field.
// A template without placeholders gets `-{index}` before its extension;
// none at all is `out/{index}.mp4`. On failure `why` says what is wrong.
batch_output :: proc(template: string, row: json.Object, index: int, allocator: mem.Allocator, why: ^Failure) -> (path: string, err: Error) {
	tpl := template
	if tpl == "" {
		tpl = BATCH_DEFAULT_OUTPUT
	} else if !strings.contains_rune(tpl, '{') {
		ext := filepath.ext(tpl)
		tpl = fmt.tprintf("%s-{{index}}%s", tpl[:len(tpl) - len(ext)], ext)
	}
	// What the placeholders read, and the first one that failed.
	Fill :: struct {
		row:       json.Object,
		index:     int,
		allocator: mem.Allocator,
		failure:   Failure,
	}
	fill := Fill{row = row, index = index, allocator = allocator}
	b := strings.builder_make(allocator)
	om.template_write(&b, tpl, &fill, proc(b: ^strings.Builder, field, mode: string, data: rawptr) -> bool {
		fill := (^Fill)(data)
		if fill.failure.code != .None {
			return true
		}
		// A colon is part of the field's name here.
		key := fmt.tprintf("%s:%s", mode, field) if mode != "" else field
		value, found := fill.row[key]
		text: string
		switch v in value {
		case json.String:
			text = v
		case json.Integer:
			text = fmt.tprint(v)
		case json.Float:
			text = fmt.tprint(v)
		case json.Boolean:
			text = "true" if v else "false"
		case json.Null:
		case json.Array, json.Object:
			fill.failure = {code = .Output_Not_Scalar, name = key}
		}
		switch {
		case !found && key == "index":
			fmt.sbprintf(b, "%d", fill.index)
		case !found:
			keys, _ := slice.map_keys(fill.row, fill.allocator)
			slice.sort(keys)
			fill.failure = {code = .Output_No_Field, name = key, names = keys}
		}
		for c in text {
			strings.write_rune(b, '_' if c == '/' || c == '\\' || c == 0 else c)
		}
		return true
	})
	if fill.failure.code != .None {
		why^ = fill.failure
		return "", why.code
	}
	return strings.to_string(b), nil
}
