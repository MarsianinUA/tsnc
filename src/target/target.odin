/*
Target platforms as data: for each platform tsnc builds for, the LLVM triple, the linker, the link
flags, the runtime object name and the pointer size. codegen, link and driver read this table, so
platform knowledge lives in one place. The package imports nothing, not even core.

The link flags follow Odin dev-2026-09-nightly:a2fb372, so the program links the way Odin links
the runtime object. On Windows Odin runs lld-link, and the flags are the output of
`odin build -linker:lld -print-linker-flags` plus tsnc's own /Brepro, which stamps the executable
with a hash of its content instead of the time, so one program always links to the same bytes. On
Linux and macOS Odin, like Rust, runs the system C compiler as the linker driver, because only the
C compiler knows where crt1.o, the dynamic loader and the SDK live on a given machine. There the
flags are what `odin build -print-linker-flags` prints, in clang syntax, read from Odin's
src/linker.cpp.

The table leaves out everything that depends on the machine: library search paths (/LIBPATH, -L,
--sysroot). It also leaves out flags for Odin features tsnc does not use: rpath, which lets shared
libraries sit next to the executable, and Odin's -L/ for foreign libraries given by full path. The
Windows system libraries are the ones the runtime's core packages import; capture them again with
the command above when the runtime imports a new core package.
*/
package target

// Target values are lowercase because they are the values of `tsnc -target:`: core:flags matches
// them against the command line by exact name, and Odin's `-target:` spells them the same way.
Target :: enum u8 {
	windows_amd64,
	linux_amd64,
	darwin_arm64,
	darwin_amd64,
	wasm32_wasi, // v2: the name is reserved, SPECS has no row for it yet
}

// HOST is the default target.
when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	HOST :: Target.windows_amd64
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	HOST :: Target.linux_amd64
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	HOST :: Target.darwin_arm64
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	HOST :: Target.darwin_amd64
} else {
	#panic("tsnc runs on windows_amd64, linux_amd64, darwin_arm64 and darwin_amd64")
}

// Linker names the program link runs and the syntax of Spec.link_flags.
Linker :: enum u8 {
	Lld_Link, // bin/lld-link.exe from the Odin distribution, MSVC link.exe syntax
	Cc, // the system C compiler as the linker driver, clang syntax
}

Spec :: struct {
	triple:            cstring, // LLVM target triple, the one Odin gives the runtime object
	linker:            Linker,
	link_flags:        []string, // one command line argument per element, unquoted
	runtime_object:    string, // file name; link looks for it next to tsnc
	executable_suffix: string,
	pointer_size:      int, // bytes
}

// SPECS is @(rodata) rather than a constant: Odin indexes a constant array only by a constant.
@(rodata)
SPECS := #partial [Target]Spec {
	.windows_amd64 = {
		triple = "x86_64-pc-windows-msvc",
		linker = .Lld_Link,
		link_flags = {
			"/ENTRY:mainCRTStartup",
			"/defaultlib:libcmt",
			"/nologo",
			"/incremental:no",
			"/opt:ref",
			"/subsystem:CONSOLE",
			"/machine:x64",
			"/Brepro",
			"kernel32.lib",
			"bcrypt.lib",
		},
		runtime_object = "tsnc_rt-windows_amd64.obj",
		executable_suffix = ".exe",
		pointer_size = 8,
	},
	.linux_amd64 = {
		triple            = "x86_64-pc-linux-gnu",
		linker            = .Cc,
		// -no-pie: distributions build PIE executables by default, and Odin and LLVM emit
		// position-dependent code by default.
		link_flags        = {"-no-pie", "-Wl,-z,now", "-Wl,-z,relro", "-lm", "-lc"},
		runtime_object    = "tsnc_rt-linux_amd64.obj",
		executable_suffix = "",
		pointer_size      = 8,
	},
	.darwin_arm64 = {
		triple = "arm64-apple-macosx11.0.0",
		linker = .Cc,
		link_flags = {"-target", "arm64-apple-macosx", "-e", "_main", "-lm"},
		runtime_object = "tsnc_rt-darwin_arm64.obj",
		executable_suffix = "",
		pointer_size = 8,
	},
	.darwin_amd64 = {
		triple = "x86_64-apple-macosx11.0.0",
		linker = .Cc,
		link_flags = {"-target", "x86_64-apple-macosx", "-e", "_main", "-lm"},
		runtime_object = "tsnc_rt-darwin_amd64.obj",
		executable_suffix = "",
		pointer_size = 8,
	},
}

// supported takes a nil triple to mean that SPECS has no row for the target.
supported :: proc(t: Target) -> bool {
	return SPECS[t].triple != nil
}
