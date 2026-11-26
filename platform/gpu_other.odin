#+build !windows
package platform

// Direct3D 12 is Windows's.
d3d12_on_hardware :: proc() -> bool {
	return false
}
