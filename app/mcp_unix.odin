#+build linux, darwin, freebsd, openbsd, netbsd
package onimite_app

import "core:sys/posix"

// The protocol's stdout: a copy of descriptor 1, which then points at
// stderr, so nothing else written to stdout (a library's or a script's
// print) reaches the client. Written as a plain descriptor: macOS can't
// give a pipe a path, which os.new_file asks for.
@(private = "file")
protocol_fd: posix.FD = posix.STDOUT_FILENO

@(private)
mcp_protocol_open :: proc() {
	fd := posix.dup(posix.STDOUT_FILENO)
	if fd < 0 {
		return
	}
	posix.dup2(posix.STDERR_FILENO, posix.STDOUT_FILENO)
	protocol_fd = fd
}

// Writes all of `s` (retrying short and interrupted writes); false when the
// client is gone.
@(private)
mcp_protocol_write :: proc(s: string) -> bool {
	rest := transmute([]u8)s
	for len(rest) > 0 {
		n := posix.write(protocol_fd, raw_data(rest), uint(len(rest)))
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return false
		}
		rest = rest[n:]
	}
	return true
}
