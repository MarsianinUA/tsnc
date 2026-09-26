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

The runtime object lies next to the running executable, where docs/development.md builds it
(dist/), unless the caller passes its path.

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
	Sanitizer_Unsupported, // -sanitize:address for a target with no ASan runtime, which is macOS
	Runtime_Object_Missing, // detail: the path looked at
	Windows_SDK_Missing, // detail: the registry value or the directory looked at
	MSVC_Missing, // detail: vswhere, or the file or directory looked at
	Linker_Missing, // detail: the linker program that could not run
	Linker_Failed, // detail: the linker's stderr
}

Link_Error :: struct {
	kind:   Error_Kind,
	detail: string, // allocated with link's allocator; empty for None and the two Unsupported
}

// Sanitizer values are lowercase because they are the values of `tsnc -sanitize:`, spelled as
// Odin's.
Sanitizer :: enum u8 {
	none,
	address, // runtime built with -sanitize:address, plus the ASan library at link time
}

// link takes an empty runtime_object to mean the runtime object of the target next to the running
// executable, the ASan one under .address.
@(require_results)
link :: proc(
	objects: []string,
	build_target: target.Target,
	output: string,
	runtime_object := "",
	sanitizer := Sanitizer.none,
	allocator := context.allocator,
) -> Link_Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	// Before the host is asked: macOS refuses the sanitizer for good, not only as another machine.
	if sanitizer == .address && target.supported(build_target) {
		if target.SPECS[build_target].asan_runtime_object == "" {
			return {kind = .Sanitizer_Unsupported}
		}
	}
	if !target.supported(build_target) || build_target != target.HOST {
		return {kind = .Unsupported_Target}
	}
	spec := target.SPECS[build_target]

	// --- Runtime object.
	runtime_path := runtime_object
	if runtime_path == "" {
		// Without the directory the name stays relative, and the check below reports it.
		executable_dir, _ := os.get_executable_directory(context.temp_allocator)
		name := spec.asan_runtime_object if sanitizer == .address else spec.runtime_object
		runtime_path = join(executable_dir, name)
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
		// What `odin build -sanitize:address -print-linker-flags` adds, from the same Odin.
		if sanitizer == .address {
			append(&command, join(ODIN_ROOT, "bin", "llvm", "windows", "clang_rt.asan-x86_64.lib"))
		}
	case .Cc:
		append(&command, "cc")
		append(&command, ..objects)
		append(&command, runtime_path, "-o", output)
		if sanitizer == .address {
			append(&command, "-fsanitize=address")
		}
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

// join allocates from the temp allocator.
@(private)
join :: proc(elems: ..string) -> string {
	path, _ := os.join_path(elems, context.temp_allocator)
	return path
}
