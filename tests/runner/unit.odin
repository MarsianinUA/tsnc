/*
The unit mode: `odin test` on every package under tests/ that has a test file, a package per thread.
A package that fails gets the whole output of `odin test` in the report.
*/
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

unit :: proc(jobs: int) -> (passed: bool) {
	paths := test_packages() or_return
	_, passed = run_programs({mode = .unit}, paths, jobs, unit_package)
	if passed {
		fmt.printfln("unit: ok (%d packages)", len(paths))
	}
	return passed
}

// test_packages answers tests/<package> and tests/<group>/<package>, sorted.
@(private = "file")
test_packages :: proc() -> (paths: []string, ok: bool) {
	groups, _ := scan("tests") or_return
	list := make([dynamic]string, context.temp_allocator)
	for group in groups {
		packages, group_tests := scan(group) or_return
		if group_tests {
			append(&list, group)
		}
		for inner in packages {
			_, inner_tests := scan(inner) or_return
			if inner_tests {
				append(&list, inner)
			}
		}
	}
	slice.sort(list[:])
	if len(list) == 0 {
		fmt.eprintln("unit: no directory under tests/ holds a _test.odin file")
		fmt.eprintln("run the runner from the repository root")
		return nil, false
	}
	return list[:], true
}

@(private = "file")
scan :: proc(directory: string) -> (subdirectories: []string, has_tests: bool, ok: bool) {
	entries, err := os.read_all_directory_by_path(directory, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("unit: read %s: %v", directory, err)
		return nil, false, false
	}
	list := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory {
			append(&list, fmt.tprintf("%s/%s", directory, entry.name))
		} else if strings.has_suffix(entry.name, "_test.odin") {
			has_tests = true
		}
	}
	return list[:], has_tests, true
}

// unit_package names the executable after the package, as tests/runtime/gc gives
// dist/runtime-gc-tests.exe.
@(private = "file")
unit_package :: proc(job: Job, path: string) -> (count: int, ok: bool) {
	name, _ := strings.replace_all(
		strings.trim_prefix(path, "tests/"),
		"/",
		"-",
		context.temp_allocator,
	)
	out := fmt.tprintf("-out:dist/%s-tests.exe", name)
	command := []string{"odin", "test", path, out, "-vet", "-strict-style"}
	output := execute(job, path, "odin test", command) or_return
	if output.code == 0 {
		return 0, true
	}
	fmt.sbprintfln(job.report, "unit: %s: odin test answered %d", path, output.code)
	fmt.sbprint(job.report, output.stdout)
	fmt.sbprint(job.report, output.stderr)
	return 0, false
}
