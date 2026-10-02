package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../../src/target"

// build_tools builds the compiler and the runtime objects with the commands of
// docs/development.md, each only when src/ holds a newer file. Any file counts: the compiler embeds
// src/lib/lib.d.ts.
build_tools :: proc(setup: Setup) -> (ok: bool) {
	newest := newest_source() or_return
	spec := target.SPECS[target.HOST]
	compiler := "dist/tsnc.exe"
	built(setup, compiler, odin_build("src", compiler), newest) or_return

	runtime := fmt.tprintf("dist/%s", spec.runtime_object)
	object := []string{"-build-mode:obj", "-use-single-module"}
	built(setup, runtime, odin_build("src/runtime", runtime, ..object), newest) or_return
	if setup.options.sanitize == .address {
		asan := fmt.tprintf("dist/%s", spec.asan_runtime_object)
		asan_object := []string{"-build-mode:obj", "-use-single-module", "-sanitize:address"}
		built(setup, asan, odin_build("src/runtime", asan, ..asan_object), newest) or_return
	}
	return true
}

odin_build :: proc(package_path, out: string, flags: ..string) -> []string {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "odin", "build", package_path, fmt.tprintf("-out:%s", out), "-o:speed")
	append(&command, ..flags)
	append(&command, "-vet", "-strict-style")
	return command[:]
}

built :: proc(setup: Setup, path: string, command: []string, newest: time.Time) -> (ok: bool) {
	if !setup.options.rebuild {
		info, err := os.stat(path, context.temp_allocator)
		if err == nil && time.diff(newest, info.modification_time) > 0 {
			return true
		}
	}
	fmt.eprintfln("bench: building %s", path)
	return build(command)
}

newest_source :: proc() -> (newest: time.Time, ok: bool) {
	walker := os.walker_create("src")
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if path, err := os.walker_error(&walker); err != nil {
			fmt.eprintfln("bench: read %s: %v", path, err)
			return {}, false
		}
		if info.type == .Regular && time.diff(newest, info.modification_time) > 0 {
			newest = info.modification_time
		}
	}
	return newest, true
}

// find_rival answers how to start scriptc or Bun, or "" when it is not installed. On Windows npm puts
// a .cmd on PATH, which os.process_start cannot start, so there the exe comes from the package in
// npm's global root.
find_rival :: proc(name: string) -> string {
	if _, ok := probe({name, "--version"}); ok {
		return name
	}
	when ODIN_OS == .Windows {
		if root, ok := probe({"cmd", "/c", "npm", "root", "-g"}); ok {
			exe := path_in(strings.trim_space(root), fmt.tprintf("%s/bin/%s.exe", name, name))
			if os.is_file(exe) {
				return exe
			}
		}
	}
	return ""
}
