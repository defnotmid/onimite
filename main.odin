// onimite: render videos written as Lua scripts. The command line only
// parses arguments into command rows (app.cli_parse, from the option table
// the MCP server shares); `app.run` applies them.
package main

import "core:fmt"
import "core:os"
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
		app.mcp_serve()
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
