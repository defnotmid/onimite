package onimite_app

import "core:encoding/json"
import "core:mem/virtual"
import "core:testing"

// CSV rows: header keys, quoted fields with commas and doubled quotes,
// numbers only where they read as JSON numbers, CRLF, BOM, blank lines.
@(test)
test_batch_rows_csv :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	text := "\xef\xbb\xbfname, role ,n,ratio,zip\r\n" +
		"Ada,\"Engines, analytical\",3,0.5,007\r\n" +
		"\r\n" +
		"\"Grace \"\"Amazing\"\" Hopper\",Compilers,-2,1e3,\r\n"
	why: Failure
	rows, err := batch_rows("rows.csv", text, a, &why)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(rows), 2)
	if len(rows) != 2 {
		return
	}
	testing.expect_value(t, rows[0]["name"].(json.String), "Ada")
	testing.expect_value(t, rows[0]["role"].(json.String), "Engines, analytical")
	testing.expect_value(t, rows[0]["n"].(json.Integer), 3)
	testing.expect_value(t, rows[0]["ratio"].(json.Float), 0.5)
	testing.expect_value(t, rows[0]["zip"].(json.String), "007")
	testing.expect_value(t, rows[1]["name"].(json.String), `Grace "Amazing" Hopper`)
	testing.expect_value(t, rows[1]["n"].(json.Integer), -2)
	testing.expect_value(t, rows[1]["ratio"].(json.Float), 1000)
	testing.expect_value(t, rows[1]["zip"].(json.String), "")

	_, ragged := batch_rows("rows.csv", "a,b\n1,2,3\n", a, &why)
	testing.expect_value(t, ragged, Error.Batch_Csv)
	_, empty := batch_rows("rows.csv", "", a, &why)
	testing.expect_value(t, empty, Error.Batch_No_Header)
	testing.expect_value(t, failure_message(why, a), "rows.csv: no header row")
}

@(test)
test_batch_rows_json :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	why: Failure
	rows, err := batch_rows("rows.json", `[{"name": "Ada", "n": 1}, {"name": "Grace", "tags": ["x"]}]`, a, &why)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[1]["name"].(json.String), "Grace")
	testing.expect_value(t, rows[0]["n"].(json.Integer), 1)
	for bad in ([]string{`{"name": "Ada"}`, `[{"name": "Ada"}, 3]`, `[{"name": `}) {
		_, e := batch_rows("rows.json", bad, a, &why)
		testing.expectf(t, e != nil, "%s should fail", bad)
	}
	testing.expect_value(t, failure_message(why, a), "rows.json: invalid JSON (Unexpected_Token)")
	batch_rows("rows.json", `[{"name": "Ada"}, 3]`, a, &why)
	testing.expect_value(t, failure_message(why, a), "rows.json: row 2 is not an object")
}

@(test)
test_batch_output :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	row := make(json.Object, a)
	row["name"] = json.String("Ada/Lovelace")
	row["n"] = json.Integer(7)
	row["x"] = json.Float(1.5)
	row["list"] = json.Array{}

	Case :: struct {
		template, want: string,
	}
	why: Failure
	cases := []Case {
		{"out/{name}.mp4", "out/Ada_Lovelace.mp4"},
		{"{index}-{n}-{x}.mp4", "3-7-1.5.mp4"},
		{"", "out/3.mp4"},
		{"card.mp4", "card-3.mp4"},
		{"frames", "frames-3"},
		{"odd{name", "odd{name"},
	}
	for c in cases {
		got, err := batch_output(c.template, row, 3, a, &why)
		testing.expectf(t, err == nil && got == c.want, "%q: got %q (%v), want %q", c.template, got, err, c.want)
	}
	// A row's own `index` field wins over the row number.
	row["index"] = json.String("own")
	got, _ := batch_output("{index}.mp4", row, 3, a, &why)
	testing.expect_value(t, got, "own.mp4")
	_, missing := batch_output("{nope}.mp4", row, 3, a, &why)
	testing.expect_value(t, missing, Error.Output_No_Field)
	testing.expect_value(t, failure_message(why, a), `no field "nope" for the output name (fields: index, list, n, name, x)`)
	_, not_scalar := batch_output("{list}.mp4", row, 3, a, &why)
	testing.expect_value(t, not_scalar, Error.Output_Not_Scalar)
}
