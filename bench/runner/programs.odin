package main

import "core:fmt"
import "core:os"
import "core:time"

@(rodata)
PROGRAMS := [?]string {
	"mandelbrot",
	"collatz",
	"sieve",
	"chars",
	"strings",
	"objects",
	"closures",
	"trees",
}
RUNS :: 5
HELLO_RUNS :: 20

// comparison prints the tables of bench/RESULTS.md: the median seconds of a run of each program,
// where hello is the startup time, then the size of hello's executable.
comparison :: proc(setup: Setup) -> (ok: bool) {
	names := make([dynamic]string, context.temp_allocator)
	for name in PROGRAMS {
		if wanted(setup, name) {
			append(&names, name)
		}
	}
	if wanted(setup, "hello") {
		append(&names, "hello")
	}
	if len(names) == 0 {
		return true
	}
	build_twins(setup) or_return

	fmt.println("| program | tsnc, s | Node, s | Go, s |")
	fmt.println("| --- | ---: | ---: | ---: |")
	sizes: [2]i64
	for name in names {
		executable := build_tsnc(setup, name) or_return
		commands := [3][]string{{executable}, {"node", source_of(name)}, {twin(setup, name)}}
		stdout := agree(setup, commands) or_return
		runs := HELLO_RUNS if name == "hello" else RUNS
		seconds: [3]f64
		for command, i in commands {
			samples := series(setup, command, stdout, runs) or_return
			seconds[i] = time.duration_seconds(median(samples).wall)
		}
		fmt.printfln("| %s | %.3f | %.3f | %.3f |", name, seconds[0], seconds[1], seconds[2])
		if name == "hello" {
			sizes = {size_of_file(executable) or_return, size_of_file(twin(setup, name)) or_return}
		}
	}
	fmt.println()
	if wanted(setup, "hello") {
		fmt.println("| hello executable | tsnc | Go |")
		fmt.println("| --- | ---: | ---: |")
		fmt.printfln("| KB | %d | %d |", sizes[0] / 1024, sizes[1] / 1024)
		fmt.println()
	}
	return true
}

size_of_file :: proc(path: string) -> (size: i64, ok: bool) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("bench: stat %s: %v", path, err)
		return 0, false
	}
	return info.size, true
}

// agree runs each implementation once and answers the output all three print. That run is also
// the warm-up: it loads the program and its libraries into the file cache, and on Windows lets the
// virus scanner see a new executable.
agree :: proc(setup: Setup, commands: [3][]string) -> (stdout: string, ok: bool) {
	outputs: [3]Output
	for command, i in commands {
		outputs[i], _ = timed(setup, command) or_return
		if outputs[i].code != 0 || outputs[i].stderr != "" {
			fmt.eprintfln(
				"bench: %s exited with %d, printing %q to stderr",
				command[0],
				outputs[i].code,
				outputs[i].stderr,
			)
			return "", false
		}
	}
	for i in 1 ..< len(outputs) {
		if outputs[i].stdout != outputs[0].stdout {
			fmt.eprintfln("bench: %s prints %q", commands[0][0], outputs[0].stdout)
			fmt.eprintfln("bench: %s prints %q", commands[i][0], outputs[i].stdout)
			return "", false
		}
	}
	return outputs[0].stdout, true
}

source_of :: proc(name: string) -> string {
	return fmt.tprintf("bench/ts/%s.ts", name)
}

build_tsnc :: proc(setup: Setup, name: string) -> (executable: string, ok: bool) {
	executable = path_in(setup.dist, fmt.tprintf("bench-%s%s", name, setup.suffix))
	out := fmt.tprintf("-out:%s", executable)
	build({setup.compiler, "build", source_of(name), "-o:speed", out}) or_return
	return executable, true
}

twin :: proc(setup: Setup, name: string) -> string {
	return path_in(setup.dist, fmt.tprintf("bench-go/%s%s", name, setup.suffix))
}

// build_twins builds every Go program at once; go build names each after its directory.
build_twins :: proc(setup: Setup) -> (ok: bool) {
	directory, err := os.get_absolute_path("bench/go", context.temp_allocator)
	if err != nil {
		fmt.eprintfln("bench: absolute path of bench/go: %v", err)
		return false
	}
	// A trailing slash makes -o a directory.
	out := fmt.tprintf("%s/", path_in(setup.dist, "bench-go"))
	return build({"go", "build", "-o", out, "./..."}, directory)
}
