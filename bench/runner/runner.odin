/*
The benchmark starter (requirements 10): hello world built by tsnc against the same file under
Node, measured by the size of the executable and the time from start to exit. T6.3 brings the real
benchmarks and the comparison with Go.

	odin run bench/runner -out:dist/bench.exe -vet -strict-style

Run it from the repository root once the compiler and the runtime object are built
(docs/development.md). Every run is checked to print the greeting, so a program that fails early
cannot pass for a fast one. CI only type-checks the runner: timings on a shared machine say little.
*/
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

import "../../src/target"

COMPILER :: "dist/tsnc.exe"
PROGRAM :: "bench/hello.ts"
GREETING :: "Hello, world!\n"
RUNS :: 20

main :: proc() {
	if !bench() {
		os.exit(1)
	}
}

bench :: proc() -> (ok: bool) {
	// Absolute paths: on Windows os.process_exec answers Not_Exist for the relative dist/tsnc.exe.
	// The executable's is built from dist/, because on Linux and macOS get_absolute_path resolves
	// only a path that exists.
	compiler, compiler_err := os.get_absolute_path(COMPILER, context.temp_allocator)
	dist, dist_err := os.get_absolute_path("dist", context.temp_allocator)
	if compiler_err != nil || dist_err != nil || !os.is_file(compiler) {
		fmt.eprintfln(
			"bench: %s is missing; run from the repository root after building it",
			COMPILER,
		)
		return false
	}
	name := fmt.tprintf("bench-hello%s", target.SPECS[target.HOST].executable_suffix)
	executable, _ := os.join_path({dist, name}, context.temp_allocator)

	build := []string{compiler, "build", PROGRAM, "-o:speed", fmt.tprintf("-out:%s", executable)}
	state, stdout, stderr, build_err := os.process_exec({command = build}, context.temp_allocator)
	if build_err != nil {
		fmt.eprintfln("bench: run %s: %v", COMPILER, build_err)
		return false
	}
	if state.exit_code != 0 {
		fmt.eprintfln("bench: %s build %s exited with %d", COMPILER, PROGRAM, state.exit_code)
		fmt.eprint(string(stdout), string(stderr))
		return false
	}
	info, stat_err := os.stat(executable, context.temp_allocator)
	if stat_err != nil {
		fmt.eprintfln("bench: stat %s: %v", executable, stat_err)
		return false
	}

	compiled := measure({executable}) or_return
	node := measure({"node", PROGRAM}) or_return
	fmt.printfln("%s, %d runs each after one warm-up", PROGRAM, RUNS)
	fmt.printfln("  tsnc executable  %d bytes", info.size)
	report("tsnc", compiled)
	report("node", node)
	return true
}

// measure answers the times sorted. The warm-up run loads the program and the libraries into the
// file cache, and on Windows lets the virus scanner see a new executable, so neither lands in the
// first timing.
measure :: proc(command: []string) -> (times: []time.Duration, ok: bool) {
	run(command) or_return
	times = make([]time.Duration, RUNS, context.temp_allocator)
	for &elapsed in times {
		start := time.tick_now()
		run(command) or_return
		elapsed = time.tick_since(start)
	}
	slice.sort(times)
	return times, true
}

run :: proc(command: []string) -> (ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("bench: run %s: %v", command[0], err)
		return false
	}
	if state.exit_code != 0 || string(stdout) != GREETING || len(stderr) > 0 {
		fmt.eprintfln(
			"bench: %s exited with %d, printing %q and %q to stderr",
			command[0],
			state.exit_code,
			string(stdout),
			string(stderr),
		)
		return false
	}
	return true
}

report :: proc(label: string, times: []time.Duration) {
	fastest := time.duration_milliseconds(times[0])
	median := time.duration_milliseconds(times[len(times) / 2])
	fmt.printfln("  %s startup     min %.1f ms, median %.1f ms", label, fastest, median)
}
