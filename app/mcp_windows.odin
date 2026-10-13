#+build windows
package onimite_app

import "core:os"

// The protocol's stdout (scripts' print goes to stderr already).
@(private)
mcp_protocol_open :: proc() {}

// Writes all of `s`; false when the client is gone.
@(private)
mcp_protocol_write :: proc(s: string) -> bool {
	_, err := os.write_string(os.stdout, s)
	return err == nil
}
