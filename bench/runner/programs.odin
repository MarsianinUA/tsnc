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

// Column is an implementation a program runs under, in the order of the table.
Column :: enum {
	tsnc,
	scriptc,
	node,
	bun,
	go,
}

// The other two are optional: when one is missing or fails a program, its cell says so and the run
// goes on.
REQUIRED :: bit_set[Column]{.tsnc, .node, .go}

// LIMIT_SECONDS stops an optional program that never ends: scriptc 0.2.1 never finishes sieve.
LIMIT_SECONDS :: 30

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
// tsnc alone and prints its change instead, since the others are the same before and after.
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
		fmt.println("| program | tsnc, s | scriptc, s | Node, s | Bun, s | Go, s |")
		fmt.println("| --- | ---: | ---: | ---: | ---: | ---: |")
	}
	now := make(map[string]f64, context.temp_allocator)
	gc_rows := make([dynamic]string, context.temp_allocator)
	sizes := [Column]string {
		.tsnc ..= .go = "—",
	}
	for name in names {
		executable := build_tsnc(setup, name) or_return
		scriptc := []string{build_scriptc(setup, name) or_return}
		source := source_of(name)
		bun := []string{setup.bun, source}
		commands := [Column][]string {
			.tsnc    = {executable},
			.scriptc = scriptc if scriptc[0] != "" else nil,
			.node    = {"node", source},
			.bun     = bun if setup.bun != "" else nil,
			.go      = {twin(setup, name)},
		}
		stdout, late := agree(setup, &commands) or_return
		cells := [Column]string {
			.tsnc ..= .go = "—",
		}
		for column in late {
			cells[column] = fmt.tprintf("> %d", LIMIT_SECONDS)
		}
		runs := HELLO_RUNS if name == "hello" else setup.options.runs
		for command, column in commands {
			if command == nil || (against && column != .tsnc) {
				continue
			}
			samples, timed := series(setup, command, stdout, runs)
			if !timed {
				if column in REQUIRED {
					return false
				}
				continue
			}
			sample := middle(samples)
			cells[column] = fmt.tprintf("%.3f", time.duration_seconds(sample.wall))
			if column == .tsnc {
				now[name] = time.duration_seconds(sample.wall)
				if setup.options.gc {
					append(&gc_rows, gc_row(name, sample.gc) or_return)
				}
			}
		}
		if against {
			change_row(setup.before, name, now[name])
		} else {
			row := slice.enumerated_array(&cells)
			fmt.printfln("| %s | %s |", name, strings.join(row, " | ", context.temp_allocator))
		}
		if name == "hello" {
			for column in ([]Column{.tsnc, .scriptc, .go}) {
				if commands[column] != nil {
					size := size_of_file(commands[column][0]) or_return
					sizes[column] = fmt.tprintf("%d", size / 1024)
				}
			}
		}
	}
	fmt.println()
	if wanted(setup, "hello") {
		fmt.println("| hello executable | tsnc | scriptc | Go |")
		fmt.println("| --- | ---: | ---: | ---: |")
		fmt.printfln("| KB | %s | %s | %s |", sizes[.tsnc], sizes[.scriptc], sizes[.go])
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

// agree runs each implementation once and answers what tsnc prints, which Node and Go must print
// too. An optional one that fails, prints something else or runs past LIMIT_SECONDS loses its
// command, and `late` holds those of the last kind. That run is also the warm-up: it loads the
// program and its libraries into the file cache, and on Windows lets the virus scanner see a new
// executable.
agree :: proc(
	setup: Setup,
	commands: ^[Column][]string,
) -> (
	stdout: string,
	late: bit_set[Column],
	ok: bool,
) {
	outputs: [Column]Output
	for command, column in commands {
		if command != nil {
			limit := os.TIMEOUT_INFINITE if column in REQUIRED else LIMIT_SECONDS * time.Second
			outputs[column], _ = timed(setup, command, limit) or_return
		}
	}
	stdout = outputs[.tsnc].stdout
	for &command, column in commands {
		output := outputs[column]
		problem: string
		switch {
		case command == nil:
			continue
		case output.killed:
			problem = fmt.tprintf("ran for more than %d s", LIMIT_SECONDS)
		case output.code != 0 || output.stderr != "":
			problem = fmt.tprintf(
				"exited with %d, printing %q to stderr",
				output.code,
				output.stderr,
			)
		case output.stdout != stdout:
			problem = fmt.tprintf("prints %q, while tsnc prints %q", output.stdout, stdout)
		case:
			continue
		}
		fmt.eprintfln("bench: %s %s", strings.join(command, " ", context.temp_allocator), problem)
		if column in REQUIRED {
			return "", {}, false
		}
		if output.killed {
			late += {column}
		}
		command = nil
	}
	return stdout, late, true
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
	remove_stale(executable) or_return
	build(command[:]) or_return
	return executable, true
}

// build_scriptc answers "" when scriptc is missing or cannot build the program. It builds at its own
// default level, release, whatever -o says.
build_scriptc :: proc(setup: Setup, name: string) -> (executable: string, ok: bool) {
	if setup.scriptc == "" {
		return "", true
	}
	executable = path_in(setup.dist, fmt.tprintf("bench-scriptc/%s%s", name, setup.suffix))
	remove_stale(executable) or_return
	if !build({setup.scriptc, "build", source_of(name), "-o", executable}) {
		return "", true
	}
	return executable, true
}

// remove_stale removes the last run's program: a build that answers 0 and writes nothing must not
// leave it to time.
remove_stale :: proc(executable: string) -> (ok: bool) {
	if err := os.remove(executable); err != nil && err != .Not_Exist {
		fmt.eprintfln("bench: remove %s: %v", executable, err)
		return false
	}
	return true
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
