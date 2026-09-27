package main

import "core:fmt"
import "core:os"
import "core:strings"

// A generated project: FEATURES modules, each with STEPS functions that call one pair of the
// LIB_FUNCTIONS pairs of one of the LIBS lib modules, and a run that calls every step.
FEATURES :: 1000
LIBS :: 10
LIB_FUNCTIONS :: 40
STEPS :: 40
COMPILE_RUNS :: 5

// The features call the same functions in every shape; only where those live and what main asks
// for change. A checker reads the body of every function it looks up, in any file.
Shape :: enum {
	apart, // each feature holds its own copies of what it calls; main imports it for its effects
	shared, // the features import the libs; main as in apart
	layered, // as shared, and main calls the run of every feature
}

Project :: struct {
	entry:        string,
	files, lines: int,
}

compile :: proc(setup: Setup) -> (ok: bool) {
	if !wanted(setup, "compile") {
		return true
	}
	jobs := os.get_processor_core_count()
	fmt.printfln("Compile, `tsnc check`, median of %d runs, wall ms (CPU ms):", COMPILE_RUNS)
	fmt.println()
	fmt.printfln("| shape | files | lines | -j:1 | -j:%d | speed-up | work on one CPU |", jobs)
	fmt.println("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")

	layered: Project
	layered_check: Sample
	for shape in Shape {
		project := write_project(setup, shape) or_return
		one := time_check(setup, project, 1) or_return
		all := time_check(setup, project, jobs) or_return
		work := one_cpu_work(setup, project, jobs) or_return
		fmt.printfln(
			"| %v | %d | %d | %.0f (%.0f) | %.0f (%.0f) | %.2f | %s |",
			shape,
			project.files,
			project.lines,
			ms(one.wall),
			ms(one.cpu),
			ms(all.wall),
			ms(all.cpu),
			ms(one.wall) / ms(all.wall),
			work,
		)
		layered, layered_check = project, all
	}
	fmt.println()
	fmt.printfln("Work on one CPU: -j:%d over -j:1 with every thread held to the same CPU.", jobs)

	none := build_once(setup, layered, "-o:none") or_return
	speed := build_once(setup, layered, "-o:speed") or_return
	fmt.printfln(
		"`tsnc build` of layered: %.1f s at -o:none, %.1f s at -o:speed; check at -j:%d is %.0f%% of -o:none.",
		ms(none.wall) / 1000,
		ms(speed.wall) / 1000,
		jobs,
		100 * ms(layered_check.wall) / ms(none.wall),
	)
	fmt.println()
	return true
}

time_check :: proc(setup: Setup, project: Project, jobs: int) -> (sample: Sample, ok: bool) {
	command := []string{setup.compiler, "check", project.entry, fmt.tprintf("-j:%d", jobs)}
	checked(setup, command, "") or_return
	return median(series(setup, command, "", COMPILE_RUNS) or_return), true
}

// one_cpu_work leaves out what the hardware adds at -j:N (slower cores, shared caches, a lower
// clock), so what stays is the work the checkers repeat and the cost of the threads.
one_cpu_work :: proc(setup: Setup, project: Project, jobs: int) -> (ratio: string, ok: bool) {
	when ODIN_OS == .Windows {
		restore := pin_to_one_cpu() or_return
		defer unpin(restore)
		one := time_check(setup, project, 1) or_return
		all := time_check(setup, project, jobs) or_return
		return fmt.tprintf("%.2f", ms(all.wall) / ms(one.wall)), true
	} else {
		// direct: pinning on Windows only; sched_setaffinity when the benchmarks run on Linux.
		return "n/a", true
	}
}

build_once :: proc(setup: Setup, project: Project, level: string) -> (sample: Sample, ok: bool) {
	executable := path_in(setup.dist, fmt.tprintf("bench-compile%s", setup.suffix))
	out := fmt.tprintf("-out:%s", executable)
	return checked(setup, {setup.compiler, "build", project.entry, level, out}, "")
}

write_project :: proc(setup: Setup, shape: Shape) -> (project: Project, ok: bool) {
	directory := path_in(setup.dist, fmt.tprintf("bench-compile-%v", shape))
	if err := os.make_directory_all(path_in(directory, "lib")); err != nil {
		fmt.eprintfln("bench: create %s: %v", directory, err)
		return {}, false
	}

	b := strings.builder_make(context.temp_allocator)
	if shape != .apart {
		for lib in 0 ..< LIBS {
			strings.builder_reset(&b)
			write_interface(&b, lib, exported = true)
			for function in 0 ..< LIB_FUNCTIONS {
				write_pair(&b, lib, function, exported = true)
			}
			write_file(&project, path_in(directory, fmt.tprintf("lib/l%d.ts", lib)), &b) or_return
		}
	}
	for feature in 0 ..< FEATURES {
		strings.builder_reset(&b)
		write_feature(&b, shape, feature)
		write_file(&project, path_in(directory, fmt.tprintf("f%03d.ts", feature)), &b) or_return
	}

	strings.builder_reset(&b)
	for feature in 0 ..< FEATURES {
		if shape == .layered {
			fmt.sbprintfln(&b, "import {{ run%d }} from \"./f%03d.ts\";", feature, feature)
		} else {
			fmt.sbprintfln(&b, "import \"./f%03d.ts\";", feature)
		}
	}
	if shape == .layered {
		fmt.sbprintln(&b, "let total = 0;")
		for feature in 0 ..< FEATURES {
			fmt.sbprintfln(&b, "total += run%d();", feature)
		}
		fmt.sbprintln(&b, "console.log(total);")
	}
	project.entry = path_in(directory, "main.ts")
	write_file(&project, project.entry, &b) or_return
	return project, true
}

// Step `step` of `feature` calls pair `function` of lib `lib`: no two steps of a feature share one.
step_target :: proc(feature, step: int) -> (lib, function: int) {
	return (feature + 3 * step) % LIBS, (feature + step) % LIB_FUNCTIONS
}

write_feature :: proc(b: ^strings.Builder, shape: Shape, feature: int) {
	for lib in 0 ..< LIBS {
		used := false
		for step in 0 ..< STEPS {
			if target_lib, _ := step_target(feature, step); target_lib == lib {
				used = true
			}
		}
		if !used {
			continue
		}
		if shape == .apart {
			write_interface(b, lib, exported = false)
		} else {
			fmt.sbprintfln(b, "import type {{ Shape%d }} from \"./lib/l%d.ts\";", lib, lib)
		}
		for step in 0 ..< STEPS {
			target_lib, function := step_target(feature, step)
			if target_lib != lib {
				continue
			}
			if shape == .apart {
				write_pair(b, lib, function, exported = false)
			} else {
				fmt.sbprintfln(
					b,
					"import {{ make%d_%d, score%d_%d }} from \"./lib/l%d.ts\";",
					lib,
					function,
					lib,
					function,
					lib,
				)
			}
		}
	}

	for step in 0 ..< STEPS {
		lib, function := step_target(feature, step)
		fmt.sbprintfln(b, "\nfunction step%d(n: number): number {{", step)
		fmt.sbprintfln(b, "  const shape: Shape%d = make%d_%d(n + %d);", lib, lib, function, step)
		fmt.sbprintfln(b, "  const score = score%d_%d(shape, %d);", lib, function, step % 4 + 1)
		fmt.sbprintln(b, "  return score > 0 ? score : n - score;")
		fmt.sbprintln(b, "}")
	}
	fmt.sbprintfln(b, "\nexport function run%d(): number {{", feature)
	fmt.sbprintln(b, "  let total = 0;")
	for step in 0 ..< STEPS {
		fmt.sbprintfln(b, "  total += step%d(%d);", step, feature)
	}
	fmt.sbprintln(b, "  return total;")
	fmt.sbprintln(b, "}")
}

write_interface :: proc(b: ^strings.Builder, lib: int, exported: bool) {
	fmt.sbprintfln(b, "%sinterface Shape%d {{", "export " if exported else "", lib)
	fmt.sbprintln(b, "  a: number;")
	fmt.sbprintln(b, "  b: number;")
	fmt.sbprintln(b, "  label: string;")
	fmt.sbprintln(b, "}")
}

write_pair :: proc(b: ^strings.Builder, lib, function: int, exported: bool) {
	export := "export " if exported else ""
	fmt.sbprintfln(b, "\n%sfunction make%d_%d(n: number): Shape%d {{", export, lib, function, lib)
	fmt.sbprintfln(
		b,
		"  const shape: Shape%d = {{ a: n, b: n * %d, label: \"l%d\" }};",
		lib,
		function + 2,
		lib,
	)
	fmt.sbprintln(b, "  if (shape.a > 10) {")
	fmt.sbprintln(b, "    shape.b = shape.b - shape.a;")
	fmt.sbprintln(b, "  }")
	fmt.sbprintln(b, "  return shape;")
	fmt.sbprintln(b, "}")
	fmt.sbprintfln(
		b,
		"\n%sfunction score%d_%d(shape: Shape%d, k: number): number {{",
		export,
		lib,
		function,
		lib,
	)
	fmt.sbprintln(b, "  let total = 0;")
	fmt.sbprintln(b, "  for (let i = 0; i < k; i++) {")
	fmt.sbprintln(b, "    total += shape.a * i - shape.b;")
	fmt.sbprintln(b, "  }")
	fmt.sbprintln(b, "  return total + shape.label.length;")
	fmt.sbprintln(b, "}")
}

write_file :: proc(project: ^Project, path: string, b: ^strings.Builder) -> (ok: bool) {
	text := strings.to_string(b^)
	if err := os.write_entire_file(path, text); err != nil {
		fmt.eprintfln("bench: write %s: %v", path, err)
		return false
	}
	project.files += 1
	project.lines += strings.count(text, "\n")
	return true
}
