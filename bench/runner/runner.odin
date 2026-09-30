/*
The benchmarks of requirements 10. docs/development.md#benchmarks says what each table measures,
what the flags do and how a version's results reach bench/RESULTS.md.

	bench/bench.sh [names] [flags]

bench/bench.sh and bench\bench.cmd run this package from the repository root; -help lists the
flags. The names pick programs of bench/ts, hello and compile; with no names, everything runs. A
program runs under tsnc, Node and its Go twin in bench/go, and the three must print the same
output before any run is timed, so a program that fails early cannot pass for a fast one.
*/
package main

import "core:flags"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import si "core:sys/info"
import "core:time"

import "../../src/link"
import "../../src/target"

// Optimization spells the levels as codegen.Optimization does; importing codegen would link LLVM.
Optimization :: enum {
	none,
	speed,
	aggressive,
}

Options :: struct {
	overflow: [dynamic]string `usage:"programs of bench/ts, hello or compile; everything when none"`,
	runs:     int `usage:"timed runs of a program (default: 5; hello runs 20)"`,
	o:        Optimization `usage:"level of tsnc build (default: speed)"`,
	sanitize: link.Sanitizer `usage:"link the runtime built with -sanitize:address"`,
	env:      map[string]string `usage:"-env:NAME=VALUE for everything the runner starts"`,
	rebuild:  bool `usage:"build the compiler and the runtime even when src/ is older"`,
	save:     string `usage:"write tsnc's times to dist/bench/NAME.json"`,
	against:  string `usage:"compare tsnc's times with dist/bench/NAME.json; Node and Go only check the output"`,
}

Setup :: struct {
	// Absolute: on Windows os.process_start answers Not_Exist for the relative dist/tsnc.exe.
	compiler: string,
	dist:     string,
	suffix:   string, // of an executable
	options:  Options,
	before:   Baseline, // read from -against
}

Output :: struct {
	stdout, stderr: string,
	code:           int,
}

// Sample is one run: from start to exit on the wall clock, and the process's CPU time on every core,
// which Windows counts in ticks of 15.6 ms.
Sample :: struct {
	wall, cpu: time.Duration,
}

main :: proc() {
	options := Options {
		runs = RUNS,
		o    = .speed,
	}
	flags.parse_or_exit(&options, os.args, .Odin)
	setup, ok := prepare(options)
	if !ok || !check_set() || !build_tools(setup) {
		os.exit(1)
	}
	header(setup)
	if !comparison(setup) || !compile(setup) {
		os.exit(1)
	}
}

prepare :: proc(options: Options) -> (setup: Setup, ok: bool) {
	setup.options = options
	for name in options.overflow {
		if !slice.contains(PROGRAMS[:], name) && name != "hello" && name != "compile" {
			fmt.eprintfln(
				"bench: no benchmark %q; the names are %v, hello and compile",
				name,
				PROGRAMS,
			)
			return {}, false
		}
	}
	if options.runs < 1 {
		fmt.eprintln("bench: -runs must be at least 1")
		return {}, false
	}
	if options.sanitize == .address && target.SPECS[target.HOST].asan_runtime_object == "" {
		fmt.eprintfln("bench: -sanitize:address: %v has no runtime built with ASan", target.HOST)
		return {}, false
	}
	for name, value in options.env {
		if err := os.set_env(name, value); err != nil {
			fmt.eprintfln("bench: set %s: %v", name, err)
			return {}, false
		}
	}

	if err := os.make_directory_all("dist"); err != nil {
		fmt.eprintfln("bench: create dist: %v", err)
		return {}, false
	}
	// On Linux and macOS get_absolute_path resolves only a path that exists, so an output path is
	// joined onto dist rather than resolved.
	dist, dist_err := os.get_absolute_path("dist", context.allocator)
	if dist_err != nil {
		fmt.eprintfln("bench: absolute path of dist: %v", dist_err)
		return {}, false
	}
	setup.dist = dist
	setup.compiler = path_in(dist, "tsnc.exe")
	setup.suffix = target.SPECS[target.HOST].executable_suffix
	if options.against != "" {
		setup.before = load_baseline(baseline_path(setup, options.against)) or_return
	}
	return setup, true
}

wanted :: proc(setup: Setup, name: string) -> bool {
	return len(setup.options.overflow) == 0 || slice.contains(setup.options.overflow[:], name)
}

// header is the first lines of a RESULTS.md section: the date, the machine and the other two tools.
header :: proc(setup: Setup) {
	fmt.printfln("bench, %s UTC", today())
	if version, ok := si.os_version(context.temp_allocator); ok {
		fmt.printfln("  OS    %s", version.full)
	}
	physical, logical, _ := si.cpu_core_count()
	fmt.printfln("  CPU   %s, %d cores, %d threads", si.cpu_name(), physical, logical)
	for tool in ([][]string{{"node", "--version"}, {"go", "version"}}) {
		output, ok := execute(tool)
		version := strings.trim_space(output.stdout) if ok else "missing"
		fmt.printfln("  %-5s %s", tool[0], version)
	}
	if text := flags_text(setup.options); text != "" {
		fmt.printfln("  flags %s", text)
	}
	if setup.options.against != "" {
		fmt.printf("  before %s, %s", setup.options.against, setup.before.date)
		if setup.before.flags != "" {
			fmt.printf(", %s", setup.before.flags)
		}
		fmt.println()
	}
	fmt.println()
}

today :: proc() -> string {
	year, month, day := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", year, int(month), day)
}

// flags_text names the flags that change the numbers; the default run prints none.
flags_text :: proc(options: Options) -> string {
	words := make([dynamic]string, context.temp_allocator)
	if options.o != .speed {
		append(&words, fmt.tprintf("-o:%v", options.o))
	}
	if options.runs != RUNS {
		append(&words, fmt.tprintf("-runs:%d", options.runs))
	}
	if options.sanitize != .none {
		append(&words, fmt.tprintf("-sanitize:%v", options.sanitize))
	}
	names, _ := slice.map_keys(options.env, context.temp_allocator)
	slice.sort(names)
	for name in names {
		append(&words, fmt.tprintf("-env:%s=%s", name, options.env[name]))
	}
	return strings.join(words[:], " ", context.temp_allocator)
}

path_in :: proc(directory, name: string) -> string {
	path, _ := os.join_path({directory, name}, context.temp_allocator)
	return path
}

// execute is for the untimed steps: builds and version queries.
execute :: proc(command: []string, working_dir := "") -> (output: Output, ok: bool) {
	description := os.Process_Desc {
		command     = command,
		working_dir = working_dir,
	}
	state, stdout, stderr, err := os.process_exec(description, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("bench: run %s: %v", command[0], err)
		return {}, false
	}
	return {stdout = string(stdout), stderr = string(stderr), code = state.exit_code}, true
}

build :: proc(command: []string, working_dir := "") -> (ok: bool) {
	output := execute(command, working_dir) or_return
	if output.code != 0 {
		fmt.eprintfln(
			"bench: %s exited with %d",
			strings.join(command, " ", context.temp_allocator),
			output.code,
		)
		fmt.eprint(output.stdout, output.stderr)
		return false
	}
	return true
}

// timed sends the output to files, not pipes: os.process_exec polls its pipes without pausing and
// keeps a core busy for the whole run.
timed :: proc(setup: Setup, command: []string) -> (output: Output, sample: Sample, ok: bool) {
	out_path := path_in(setup.dist, "bench-stdout.txt")
	err_path := path_in(setup.dist, "bench-stderr.txt")
	flags := os.File_Flags{.Write, .Create, .Trunc, .Inheritable}
	out, out_err := os.open(out_path, flags)
	if out_err != nil {
		fmt.eprintfln("bench: create %s: %v", out_path, out_err)
		return {}, {}, false
	}
	defer os.close(out)
	errors, errors_err := os.open(err_path, flags)
	if errors_err != nil {
		fmt.eprintfln("bench: create %s: %v", err_path, errors_err)
		return {}, {}, false
	}
	defer os.close(errors)

	start := time.tick_now()
	process, start_err := os.process_start({command = command, stdout = out, stderr = errors})
	if start_err != nil {
		fmt.eprintfln("bench: run %s: %v", command[0], start_err)
		return {}, {}, false
	}
	state, wait_err := os.process_wait(process)
	sample.wall = time.tick_since(start)
	if wait_err != nil {
		fmt.eprintfln("bench: wait for %s: %v", command[0], wait_err)
		return {}, {}, false
	}
	sample.cpu = state.user_time + state.system_time

	stdout, stdout_err := os.read_entire_file(out_path, context.temp_allocator)
	stderr, stderr_err := os.read_entire_file(err_path, context.temp_allocator)
	if stdout_err != nil || stderr_err != nil {
		fmt.eprintfln("bench: read the output of %s: %v, %v", command[0], stdout_err, stderr_err)
		return {}, {}, false
	}
	return {stdout = string(stdout), stderr = string(stderr), code = state.exit_code}, sample, true
}

// checked is one timed run that has to exit 0 and print `stdout` and nothing on stderr.
checked :: proc(setup: Setup, command: []string, stdout: string) -> (sample: Sample, ok: bool) {
	output: Output
	output, sample = timed(setup, command) or_return
	if output.code != 0 || output.stdout != stdout || output.stderr != "" {
		fmt.eprintfln(
			"bench: %s exited with %d, printing %q and %q to stderr",
			strings.join(command, " ", context.temp_allocator),
			output.code,
			output.stdout,
			output.stderr,
		)
		return {}, false
	}
	return sample, true
}

series :: proc(
	setup: Setup,
	command: []string,
	stdout: string,
	runs: int,
) -> (
	samples: []Sample,
	ok: bool,
) {
	samples = make([]Sample, runs, context.temp_allocator)
	for &sample in samples {
		sample = checked(setup, command, stdout) or_return
	}
	return samples, true
}

// median sorts the wall and the CPU times apart, so the two medians may come from different runs.
median :: proc(samples: []Sample) -> Sample {
	walls := make([]time.Duration, len(samples), context.temp_allocator)
	cpus := make([]time.Duration, len(samples), context.temp_allocator)
	for sample, i in samples {
		walls[i], cpus[i] = sample.wall, sample.cpu
	}
	slice.sort(walls)
	slice.sort(cpus)
	return {walls[len(walls) / 2], cpus[len(cpus) / 2]}
}

ms :: proc(d: time.Duration) -> f64 {
	return time.duration_milliseconds(d)
}
