package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
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

// check_set holds bench/ts and bench/go to PROGRAMS and hello both ways, so that no program runs
// without its twin and no file lies there unmeasured.
check_set :: proc() -> (ok: bool) {
	names := slice.concatenate([][]string{PROGRAMS[:], {"hello"}}, context.temp_allocator)
	ok = true
	for name in names {
		for path in ([]string{source_of(name), fmt.tprintf("bench/go/%s/main.go", name)}) {
			if !os.is_file(path) {
				fmt.eprintfln("bench: %s is missing", path)
				ok = false
			}
		}
	}

	sources := read_directory("bench/ts") or_return
	for info in sources {
		name := strings.trim_suffix(info.name, ".ts")
		if name != info.name && !slice.contains(names, name) {
			fmt.eprintfln("bench: bench/ts/%s is not in PROGRAMS", info.name)
			ok = false
		}
	}
	twins := read_directory("bench/go") or_return
	for info in twins {
		if info.type == .Directory && !slice.contains(names, info.name) {
			fmt.eprintfln("bench: bench/go/%s is not in PROGRAMS", info.name)
			ok = false
		}
	}
	return ok
}

read_directory :: proc(path: string) -> (infos: []os.File_Info, ok: bool) {
	err: os.Error
	infos, err = os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("bench: read %s: %v", path, err)
		return nil, false
	}
	return infos, true
}

// comparison prints the tables of bench/RESULTS.md: the median seconds of a run of each program,
// where hello is the startup time, then the size of hello's executable. Under -against it times
// tsnc alone and prints its change instead, since Node and Go are the same before and after.
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

	against := setup.options.against != ""
	if against {
		fmt.println("| program | before, s | now, s | change |")
		fmt.println("| --- | ---: | ---: | ---: |")
	} else {
		fmt.println("| program | tsnc, s | Node, s | Go, s |")
		fmt.println("| --- | ---: | ---: | ---: |")
	}
	now := make(map[string]f64, context.temp_allocator)
	gc_rows := make([dynamic]string, context.temp_allocator)
	sizes: [2]i64
	for name in names {
		executable := build_tsnc(setup, name) or_return
		commands := [3][]string{{executable}, {"node", source_of(name)}, {twin(setup, name)}}
		stdout := agree(setup, commands) or_return
		runs := HELLO_RUNS if name == "hello" else setup.options.runs
		seconds: [3]f64
		for command, i in commands[:1 if against else 3] {
			samples := series(setup, command, stdout, runs) or_return
			sample := middle(samples)
			seconds[i] = time.duration_seconds(sample.wall)
			if setup.options.gc && i == 0 {
				append(&gc_rows, gc_row(name, sample.gc) or_return)
			}
		}
		now[name] = seconds[0]
		if against {
			change_row(setup.before, name, seconds[0])
		} else {
			fmt.printfln("| %s | %.3f | %.3f | %.3f |", name, seconds[0], seconds[1], seconds[2])
		}
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
	if setup.options.gc {
		fmt.println(
			"| program | collections | marking, ms | sweeping, ms | longest pause, ms | cells | allocated, MB | live, MB | heap, MB |",
		)
		fmt.println("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
		for row in gc_rows {
			fmt.println(row)
		}
		fmt.println()
	}
	if setup.options.save != "" {
		baseline := Baseline {
			date  = today(),
			flags = flags_text(setup.options),
			tsnc  = now,
		}
		save_baseline(baseline_path(setup, setup.options.save), baseline) or_return
	}
	return true
}

// gc_row takes the numbers of the TSNC_GC_STATS line by position, in the order gc.write_stats
// writes them: "gc: 109 collections, 293.5 ms marking, ..., 23.3 MB heap".
gc_row :: proc(name, line: string) -> (row: string, ok: bool) {
	parts := strings.split(strings.trim_prefix(line, GC_PREFIX), ", ", context.temp_allocator)
	if !strings.has_prefix(line, GC_PREFIX) || len(parts) != 8 {
		fmt.eprintfln("bench: %s: no line of %s, but %q", name, GC_VARIABLE, line)
		return "", false
	}
	cells := make([dynamic]string, context.temp_allocator)
	append(&cells, name)
	for part in parts {
		number, _, _ := strings.partition(part, " ")
		append(&cells, number)
	}
	return fmt.tprintf("| %s |", strings.join(cells[:], " | ", context.temp_allocator)), true
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
	command := make([dynamic]string, context.temp_allocator)
	append(
		&command,
		setup.compiler,
		"build",
		source_of(name),
		fmt.tprintf("-o:%v", setup.options.o),
		fmt.tprintf("-out:%s", executable),
	)
	if setup.options.sanitize != .none {
		append(&command, fmt.tprintf("-sanitize:%v", setup.options.sanitize))
	}
	build(command[:]) or_return
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
