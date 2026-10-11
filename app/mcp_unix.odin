#+build linux, darwin, freebsd, openbsd, netbsd
package onimite_app

import "core:os"
import "core:sys/posix"

// The protocol's stdout: a copy of descriptor 1, which then points at
// stderr, so nothing else written to stdout (a library's or a script's
// print) reaches the client.
@(private)
mcp_protocol_out :: proc() -> ^os.File {
	fd := posix.dup(posix.STDOUT_FILENO)
	if fd < 0 {
		return os.stdout
	}
	posix.dup2(posix.STDERR_FILENO, posix.STDOUT_FILENO)
	return os.new_file(uintptr(fd), "mcp")
}
