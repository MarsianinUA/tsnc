package main

import "core:fmt"
import "core:os"

import "../../src/codegen"
import "../../src/link"
import "../../src/target"

// RUNTIME_BUILD builds the runtime object smoke links against; %s is its path.
RUNTIME_BUILD :: "odin build src/runtime -build-mode:obj -use-single-module -out:%s -vet -strict-style"

// smoke builds the codegen hello world for the host, links it with the runtime object in dist/,
// runs it and compares stdout, stderr and the exit code. Until `tsnc build` exists (T4.5), smoke
// calls codegen and link directly, the way driver will.
smoke :: proc() -> (passed: bool) {
	codegen.init_global_options()

	// --- Object file.
	object := "dist/smoke-hello.obj"
	if err := codegen.emit(codegen.Unit{}, target.HOST, .speed, .Object, object); err != .None {
		fmt.eprintfln("smoke: codegen %s: %v", object, err)
		if err == .Write_Failed {
			fmt.eprintln("run the runner from the repository root; create dist/ once: mkdir dist")
		}
		return false
	}

	// --- Executable. An absolute path, so the run below does not depend on how the OS resolves a
	// relative one. It is built from dist/, because on Linux and macOS get_absolute_path resolves
	// only a path that exists.
	dist, path_err := os.get_absolute_path("dist", context.temp_allocator)
	if path_err != nil {
		fmt.eprintfln("smoke: absolute path of dist: %v", path_err)
		return false
	}
	program, _ := os.join_path({dist, "smoke-hello.exe"}, context.temp_allocator)
	runtime_object := fmt.tprintf("dist/%s", target.SPECS[target.HOST].runtime_object)
	link_err := link.link({object}, target.HOST, program, runtime_object, context.temp_allocator)
	if link_err.kind != .None {
		fmt.eprintfln("smoke: link: %v: %s", link_err.kind, link_err.detail)
		if link_err.kind == .Runtime_Object_Missing {
			fmt.eprintln("build it first:", fmt.tprintf(RUNTIME_BUILD, runtime_object))
		}
		return false
	}

	// --- Run and compare. Every mismatch is reported, so one CI log shows all of them.
	state, stdout, stderr, run_err := os.process_exec(
		{command = {program}},
		context.temp_allocator,
	)
	if run_err != nil {
		fmt.eprintfln("smoke: run %s: %v", program, run_err)
		return false
	}
	want_stdout :: codegen.HELLO_WORLD + "\n"
	passed = true
	if string(stdout) != want_stdout {
		fmt.eprintfln("smoke: stdout: got %q, want %q", string(stdout), want_stdout)
		passed = false
	}
	if len(stderr) > 0 {
		fmt.eprintfln("smoke: stderr: got %q, want nothing", string(stderr))
		passed = false
	}
	if !state.success {
		fmt.eprintfln("smoke: %s crashed: exception or signal %d", program, state.exit_code)
		passed = false
	} else if state.exit_code != 0 {
		fmt.eprintfln("smoke: exit code: got %d, want 0", state.exit_code)
		passed = false
	}
	if passed {
		fmt.println("smoke: ok")
	}
	return passed
}
