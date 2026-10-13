// onimite: render videos written as Lua scripts. The command line only
// parses arguments into command rows (app.cli_parse, from the option table
// the MCP server shares); `app.run` applies them.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import app "app"

main :: proc() {
	args := os.args[1:]
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		fmt.print(app.usage())
		return
	}
	if len(args) == 1 && (args[0] == "-V" || args[0] == "--version") {
		fmt.printfln("onimite %s", app.ONIMITE_VERSION)
		return
	}
	if len(args) > 0 && args[0] == "mcp" {
		// `--dir PATH`: the folder relative paths resolve in (the MCP bundle's
		// work folder); an empty or unset PATH means the default work folder.
		// `--update-check false`: don't look for a newer release at start.
		dir, update_check := "", true
		for i := 1; i < len(args); i += 1 {
			value := args[i + 1] if i + 1 < len(args) else ""
			switch args[i] {
			case "--dir":
				dir = value
				if dir == "" || strings.has_prefix(dir, "${") {
					dir = app.mcp_default_dir()
				}
			case "--update-check":
				update_check = value != "false" && value != "0"
			case:
				fmt.eprintln("usage: onimite mcp [--dir PATH] [--update-check true|false]")
				os.exit(2)
			}
			i += 1
		}
		app.mcp_serve(dir, update_check)
		return
	}
	rows, help := app.cli_parse(args)
	if help {
		fmt.print(app.usage())
		return
	}
	if code := app.front_rows_run(rows); code != 0 {
		os.exit(code)
	}
}
