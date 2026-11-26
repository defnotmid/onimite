#+build windows
package platform

import "vendor:directx/dxgi"

// Whether SDL's Direct3D 12 driver would open a hardware adapter: the one
// it takes, DXGI's first by high-performance preference (its first adapter
// where DXGI is older), is not a software one. Hardware comes before the
// software rasterizer in both orders.
d3d12_on_hardware :: proc() -> bool {
	factory: ^dxgi.IFactory1
	if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory)) < 0 {
		return false
	}
	defer factory->Release()
	adapter: ^dxgi.IAdapter1
	factory6: ^dxgi.IFactory6
	if factory->QueryInterface(dxgi.IFactory6_UUID, (^rawptr)(&factory6)) >= 0 {
		defer factory6->Release()
		if factory6->EnumAdapterByGpuPreference(0, .HIGH_PERFORMANCE, dxgi.IAdapter1_UUID, (^rawptr)(&adapter)) < 0 {
			return false
		}
	} else if factory->EnumAdapters1(0, &adapter) < 0 {
		return false
	}
	defer adapter->Release()
	desc: dxgi.ADAPTER_DESC1
	if adapter->GetDesc1(&desc) < 0 {
		return false
	}
	return .SOFTWARE not_in desc.Flags
}
