#+build windows
package onimite_app

import "core:os"

// The protocol's stdout (scripts' print goes to stderr already).
@(private)
mcp_protocol_out :: proc() -> ^os.File {
	return os.stdout
}
