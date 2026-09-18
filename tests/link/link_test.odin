package link_tests

import "core:os"
import "core:strings"
import "core:testing"

import "../../src/codegen"
import "../../src/link"
import "../../src/target"

// The test runner runs tests on a thread pool, so LLVM's process-global setup happens once before
// the pool starts, the way driver sets it up before its own pool.
@(init)
init_llvm :: proc "contextless" () {
	codegen.init_global_options()
}

// link finds the runtime object next to the test executable, in dist/, so it has to be built
// before these tests run.
RUNTIME_BUILD :: "odin build src/runtime -build-mode:obj -use-single-module -out:dist/tsnc_rt-<target>.obj -vet -strict-style"

@(test)
hello_world_links_and_runs :: proc(t: ^testing.T) {
	object := "dist/link-hello.obj"
	emit_err := codegen.emit(codegen.Unit{}, target.HOST, .speed, .Object, object)
	if !testing.expect_value(t, emit_err, codegen.Error.None) {
		return
	}

	// An absolute path, so the run below does not depend on how the OS resolves a relative one.
	dir, _ := os.get_executable_directory(context.temp_allocator)
	program, _ := os.join_path({dir, "link-hello.exe"}, context.temp_allocator)
	err := link.link({object}, target.HOST, program)
	defer delete(err.detail)
	if !testing.expectf(
		t,
		err.kind == .None,
		"%v: %s\nbuild the runtime object first: %s",
		err.kind,
		err.detail,
		RUNTIME_BUILD,
	) {
		return
	}

	state, stdout, stderr, run_err := os.process_exec({command = {program}}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	if !testing.expectf(t, run_err == nil, "run %s: %v", program, run_err) {
		return
	}
	testing.expect_value(t, string(stdout), codegen.HELLO_WORLD + "\n")
	testing.expect_value(t, string(stderr), "")
	testing.expect_value(t, state.exit_code, 0)

	// The runtime object exports its procedures, and without /noimplib lld-link would write an
	// import library next to the program.
	when ODIN_OS == .Windows {
		import_library, _ := os.join_path({dir, "link-hello.lib"}, context.temp_allocator)
		testing.expectf(t, !os.exists(import_library), "%s was written", import_library)
	}
}

@(test)
missing_runtime_object_is_reported :: proc(t: ^testing.T) {
	missing := "dist/link-missing/tsnc_rt.obj"
	err := link.link({"dist/link-hello.obj"}, target.HOST, "dist/link-missing.exe", missing)
	defer delete(err.detail)
	testing.expect_value(t, err.kind, link.Error_Kind.Runtime_Object_Missing)
	testing.expect_value(t, err.detail, missing)
}

// Without a program object nothing defines tsnc_main, which the runtime calls. lld-link, GNU ld and
// ld64 all name the undefined symbol.
@(test)
linker_stderr_reaches_the_error :: proc(t: ^testing.T) {
	err := link.link({}, target.HOST, "dist/link-no-program.exe")
	defer delete(err.detail)
	testing.expectf(t, err.kind == .Linker_Failed, "%v: %s", err.kind, err.detail)
	testing.expectf(
		t,
		strings.contains(err.detail, "tsnc_main"),
		"the linker's stderr lacks tsnc_main:\n%s",
		err.detail,
	)
}

@(test)
only_the_host_target_links :: proc(t: ^testing.T) {
	for id in target.Target {
		if id == target.HOST {
			continue
		}
		err := link.link({"dist/link-hello.obj"}, id, "dist/link-other.exe")
		testing.expectf(t, err.kind == .Unsupported_Target, "%v: %v", id, err.kind)
		testing.expect_value(t, err.detail, "")
	}
}
