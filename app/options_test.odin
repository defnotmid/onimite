package onimite_app

import "core:strings"
import "core:testing"

// The command line finds an option by its spelling among the options of
// its command (option_of checks each field's tags as it reads them; the
// compiler keeps a tool's argument names apart).
@(test)
test_options_table :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for d, kind in COMMAND_KINDS {
		if .Command_Line not_in d.flags {
			continue
		}
		for o in command_options(kind) {
			names := o.cli
			for name in strings.split_iterator(&names, "|") {
				found, _, takes := option_find_cli(name, kind)
				testing.expectf(t, takes && found.name == o.name, "%v: %s means another option", kind, name)
			}
		}
		_, ok := option_positional(kind)
		testing.expectf(t, ok || d.missing == "", "%v needs a positional argument it has no option for", kind)
	}
}

// Arguments fill the rows in their order: settings, the script load, the
// scale, the command. Defaults come from the command; a batch loads the
// media only, the preview the script only.
@(test)
test_cli_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rows, help := cli_parse({"frames", "v.lua", "1s", "2s", "-o", "out", "--svg", "--scale", "0.5", "--set", "a=1", "--json", "--", "p"})
	testing.expect(t, !help)
	testing.expect_value(t, rows[.Command].kind, Command_Kind.Frame)
	testing.expect_value(t, rows[.Command].regs.spec, "1s,2s")
	testing.expect_value(t, rows[.Command].regs.path, "out")
	testing.expect_value(t, rows[.Command].regs.flags, Command_Flags{.Svg})
	testing.expect_value(t, rows[.Load].regs.path, "v.lua")
	testing.expect_value(t, rows[.Load].regs.args, "a=1\np")
	testing.expect_value(t, rows[.Scale].regs.scalar, 0.5)
	testing.expect(t, rows[.Output].regs.flag)
	testing.expect_value(t, rows[.Threads].kind, Command_Kind.None)

	rows, _ = cli_parse({"audio", "onsets", "v.lua"})
	testing.expect_value(t, rows[.Command].regs.ratio, 0.1)
	rows, _ = cli_parse({"inspect", "v.lua", "--fail-on", "never", "--threads", "2.9"})
	testing.expect_value(t, rows[.Command].regs.option, int(Fail_On.Never))
	testing.expect_value(t, rows[.Threads], Command_Row{.Threads_Set, {count = 2}})
	_, help = cli_parse({"show", "v.lua", "--help"})
	testing.expect(t, help)

	// The rows the arguments push, as pushed (all in temp memory).
	pushed :: proc(args: ..string) -> []Command_Row {
		context.allocator = context.temp_allocator
		c := command_storage_make()
		rows, _ := cli_parse(args)
		front_rows_push(&c, rows)
		out := make([]Command_Row, len(c.pending.rows))
		for q, i in c.pending.rows {
			out[i] = command_row_of(&c.pending, q)
		}
		return out
	}
	batch := pushed("v.lua", "--batch", "rows.csv", "--rows", "2..", "--image-cache", "64")
	kinds := make([dynamic]Command_Kind, context.temp_allocator)
	for row in batch {
		append(&kinds, row.kind)
	}
	testing.expect_value(t, len(kinds), 7)
	if len(kinds) == 7 {
		testing.expect_value(t, kinds[3], Command_Kind.Image_Cache_Set)
		testing.expect_value(t, kinds[4], Command_Kind.Script_Load)
		testing.expect_value(t, batch[4].regs.flags, Command_Flags{.No_Script})
		testing.expect_value(t, kinds[6], Command_Kind.Batch_Render)
		testing.expect_value(t, batch[6].regs.props, "rows.csv")
		testing.expect_value(t, batch[6].regs.rows, [2]int{2, 0})
	}
	preview := pushed("preview", "v.lua", "3s", "--paused")
	last := preview[len(preview) - 1]
	testing.expect_value(t, preview[len(preview) - 3].regs.flags, Command_Flags{.No_Media})
	testing.expect_value(t, last.regs.flags, Command_Flags{.Paused})
	testing.expect_value(t, last.regs.spec, "3s")
	probe := pushed("probe", "a.mp4", "b.mp4")
	last = probe[len(probe) - 1]
	testing.expect_value(t, len(probe), 4)
	testing.expect_value(t, last.kind, Command_Kind.Probe)
	testing.expect_value(t, last.regs.args, "a.mp4\nb.mp4")
}

// A row outside its kind's domain, or without a string register its kind
// needs, fails before its handler sees it.
@(test)
test_command_validate :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	app: App_State
	app_init(&app)
	defer app_destroy(&app)
	row := Command_Row{.Frame_Step, {count = 1}}
	testing.expect_value(t, command_validate(&app, &row), Error.Command_Domain)
	testing.expect_value(t, failure_message(app.failure, context.temp_allocator), "frame_step runs only in the preview window")
	failure_clear(&app)
	app.script_loaded = true
	row = {.Onion, {}}
	testing.expect_value(t, command_validate(&app, &row), Error.Command_Needs)
	testing.expect_value(t, failure_message(app.failure, context.temp_allocator), "onion needs a range")
	failure_clear(&app)
	row = {.Onion, {spec = "0..10"}}
	testing.expect_value(t, command_validate(&app, &row), Error.None)
}
