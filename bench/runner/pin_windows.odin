package main

import "core:fmt"
import win32 "core:sys/windows"

// pin_to_one_cpu holds this process, and every process it starts from now on, to one logical CPU
// and answers the mask that undoes it. CPU 2 rather than 0, which takes most interrupts; on a
// hybrid Intel it is a performance core.
pin_to_one_cpu :: proc() -> (restore: win32.DWORD_PTR, ok: bool) {
	process := win32.GetCurrentProcess()
	system: win32.DWORD_PTR
	if !win32.GetProcessAffinityMask(process, &restore, &system) {
		fmt.eprintfln("bench: GetProcessAffinityMask: %v", win32.GetLastError())
		return 0, false
	}
	one := win32.DWORD_PTR(1 << 2)
	if system & one == 0 {
		one = system & -system
	}
	if !win32.SetProcessAffinityMask(process, one) {
		fmt.eprintfln("bench: SetProcessAffinityMask: %v", win32.GetLastError())
		return 0, false
	}
	return restore, true
}

unpin :: proc(restore: win32.DWORD_PTR) {
	win32.SetProcessAffinityMask(win32.GetCurrentProcess(), restore)
}
