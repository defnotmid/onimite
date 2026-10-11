#+build linux
package onimite_speech

foreign import libc "system:c"

@(private, default_calling_convention = "c")
foreign libc {
	malloc_trim :: proc(pad: uint) -> i32 ---
}

// The engine's memory goes back to the system: glibc keeps freed heap
// memory (about 1 GB of it after `release`) unless asked to return it.
@(private)
heap_trim :: proc() {
	malloc_trim(0)
}
