/*
The program objects and the runtime object into an executable, through the linker that
target.SPECS names, with its flags.

Windows: bin/lld-link.exe of the Odin distribution that built tsnc, the lld-link Odin itself runs.
The table leaves out the library directories, because they depend on the machine; link finds them
the way Odin, Rust and Zig do: the Windows SDK through the registry, the MSVC libraries through
vswhere (library_dirs_windows.odin).

Linux and macOS: the system C compiler, cc, finds the C runtime startup files, the dynamic loader
and the libraries itself. On macOS /usr/bin/cc is the Xcode shim that picks the SDK. Odin passes
--sysroot from `xcrun --show-sdk-path` on top of that; link adds it once CI shows a machine that
needs it.

The runtime object lies next to the running executable, where the README builds it (dist/), unless
the caller passes its path.

v1 links for the host only (requirements 9): linking for another platform needs its libraries,
which v2 cross-compilation adds to target.

Errors: link returns a Link_Error, like every infrastructure failure in tsnc a value of its package
that driver translates. Its detail is the linker's stderr, or what link looked for and did not find.
*/
package link

import "base:runtime"
import "core:os"
import "core:strings"

import "../target"

Error_Kind :: enum u8 {
	None,
	Unsupported_Target, // no target.SPECS row, or not the host: v1 links natively only
	Runtime_Object_Missing, // detail: the path looked at
	Windows_SDK_Missing, // detail: the registry value or the directory looked at
	MSVC_Missing, // detail: vswhere, or the file or directory looked at
	Linker_Missing, // detail: the linker program that could not run
	Linker_Failed, // detail: the linker's stderr
}

Link_Error :: struct {
	kind:   Error_Kind,
	detail: string, // allocated with link's allocator; empty for None and Unsupported_Target
}

// link links the program objects and the runtime object into the executable at output. An empty
// runtime_object means the runtime object of the target next to the running executable.
@(require_results)
link :: proc(
	objects: []string,
	build_target: target.Target,
	output: string,
	runtime_object := "",
	allocator := context.allocator,
) -> Link_Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	if !target.supported(build_target) || build_target != target.HOST {
		return {kind = .Unsupported_Target}
	}
	spec := target.SPECS[build_target]

	// --- Runtime object.
	runtime_path := runtime_object
	if runtime_path == "" {
		// Without the directory the name stays relative, and the check below reports it.
		executable_dir, _ := os.get_executable_directory(context.temp_allocator)
		runtime_path = join(executable_dir, spec.runtime_object)
	}
	if !os.is_file(runtime_path) {
		return {.Runtime_Object_Missing, strings.clone(runtime_path, allocator)}
	}

	// --- Command line: linker, objects, output, library directories, flags.
	command := make([dynamic]string, context.temp_allocator)
	switch spec.linker {
	case .Lld_Link:
		// direct: the Odin that built tsnc, as the plan assumes (architecture plan, "Assumptions");
		// an option with the linker path once tsnc ships without Odin.
		append(&command, join(ODIN_ROOT, "bin", "lld-link.exe"))
		append(&command, ..objects)
		append(
			&command,
			runtime_path,
			strings.concatenate({"/out:", output}, context.temp_allocator),
		)
		when ODIN_OS == .Windows {
			dirs, dirs_err := windows_library_dirs()
			if dirs_err.kind != .None {
				return {dirs_err.kind, strings.clone(dirs_err.detail, allocator)}
			}
			for dir in dirs {
				append(&command, strings.concatenate({"/libpath:", dir}, context.temp_allocator))
			}
		} else {
			// SPECS pairs lld-link only with windows_amd64, and link builds for the host only.
			unreachable()
		}
	case .Cc:
		append(&command, "cc")
		append(&command, ..objects)
		append(&command, runtime_path, "-o", output)
	}
	append(&command, ..spec.link_flags)

	// --- Run.
	state, _, stderr, run_err := os.process_exec({command = command[:]}, context.temp_allocator)
	if run_err != nil {
		return {.Linker_Missing, strings.clone(command[0], allocator)}
	}
	if !state.success || state.exit_code != 0 {
		return {.Linker_Failed, strings.clone(string(stderr), allocator)}
	}
	return {}
}

// join joins path elements with the host separator into the temp allocator.
@(private)
join :: proc(elems: ..string) -> string {
	path, _ := os.join_path(elems, context.temp_allocator)
	return path
}
