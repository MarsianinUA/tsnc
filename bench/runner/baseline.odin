package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

// Baseline is what -save writes and -against reads back: tsnc's median seconds by program.
Baseline :: struct {
	date:  string,
	flags: string,
	tsnc:  map[string]f64,
}

baseline_path :: proc(setup: Setup, name: string) -> string {
	return path_in(setup.dist, fmt.tprintf("bench/%s.json", name))
}

load_baseline :: proc(path: string) -> (baseline: Baseline, ok: bool) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("bench: read %s: %v; -save writes it", path, read_err)
		return {}, false
	}
	if err := json.unmarshal(data, &baseline, allocator = context.temp_allocator); err != nil {
		fmt.eprintfln("bench: read %s: %v", path, err)
		return {}, false
	}
	return baseline, true
}

save_baseline :: proc(path: string, baseline: Baseline) -> (ok: bool) {
	if err := os.make_directory_all(os.dir(path)); err != nil {
		fmt.eprintfln("bench: create %s: %v", os.dir(path), err)
		return false
	}
	options := json.Marshal_Options {
		pretty           = true,
		sort_maps_by_key = true,
	}
	data, marshal_err := json.marshal(baseline, options, context.temp_allocator)
	if marshal_err != nil {
		fmt.eprintfln("bench: write %s: %v", path, marshal_err)
		return false
	}
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("bench: write %s: %v", path, err)
		return false
	}
	return true
}

change_row :: proc(table: Table, before: Baseline, name: string, now: f64) {
	was, found := before.tsnc[name]
	if !found {
		print_row(table, {name, "n/a", fmt.tprintf("%.3f", now), "n/a"})
		return
	}
	change := fmt.tprintf("%+.1f%%", 100 * (now - was) / was)
	print_row(table, {name, fmt.tprintf("%.3f", was), fmt.tprintf("%.3f", now), change})
}
