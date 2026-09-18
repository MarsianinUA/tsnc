package main

import "core:flags"
import "core:fmt"
import "core:os"

import "target"

// Enum values in this file are lowercase because core:flags matches them against the
// command line by exact name: `tsnc build`, `-o:none`.

Command :: enum {
	build,
	run,
	check,
}

// Same names as `odin -o`: speed runs the LLVM pipeline default<O2>, aggressive runs default<O3>.
Optimization :: enum {
	none,
	speed,
	aggressive,
}

Options :: struct {
	command:      Command `args:"pos=0,required" usage:"build, run or check"`,
	input:        string `args:"pos=1,required" usage:"entry .ts file"`,
	output:       string `args:"name=out" usage:"output path"`,
	optimization: Optimization `args:"name=o" usage:"optimization level (default: speed)"`,
	emit_llvm:    bool `usage:"write textual LLVM IR instead of an executable"`,
	emit_ir:      bool `usage:"write the tsnc IR dump instead of an executable"`,
	// Text, not target.Target: target.parse is the one place that checks the name, and it also
	// rejects targets that have no row yet.
	target:       string `usage:"target platform, for example linux_amd64 (default: host)"`,
	jobs:         int `args:"name=j" usage:"worker threads (default: number of cores)"`,
}

main :: proc() {
	options := Options {
		optimization = .speed,
		jobs         = os.get_processor_core_count(),
	}
	flags.parse_or_exit(&options, os.args, .Odin)

	// stderr only: stdout belongs to the compiled program under `tsnc run`.
	build_target := target.HOST
	if options.target != "" {
		err: target.Parse_Error
		build_target, err = target.parse(options.target)
		switch err {
		case .None:
		case .Unknown:
			fmt.eprintf("unknown target %q; supported: ", options.target)
			separator := ""
			for name, id in target.NAMES {
				if target.supported(id) {
					fmt.eprintf("%s%s", separator, name)
					separator = ", "
				}
			}
			fmt.eprintln()
			os.exit(1)
		case .Unsupported:
			fmt.eprintfln("target %q is not supported yet", options.target)
			os.exit(1)
		}
	}

	fmt.eprintfln("%#v", options)
	fmt.eprintfln("target: %v", build_target)
	fmt.eprintfln("tsnc %v: not implemented", options.command)
	os.exit(1)
}
