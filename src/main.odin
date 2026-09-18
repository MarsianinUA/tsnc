package main

import "core:flags"
import "core:fmt"
import "core:os"

import "codegen"
import "target"

// Command values are lowercase because core:flags matches them against the command line by exact
// name: `tsnc build`. codegen.Optimization and target.Target follow the same rule for `-o:` and
// `-target:`.
Command :: enum {
	build,
	run,
	check,
}

Options :: struct {
	command:      Command `args:"pos=0,required" usage:"build, run or check"`,
	input:        string `args:"pos=1,required" usage:"entry .ts file"`,
	output:       string `args:"name=out" usage:"output path"`,
	optimization: codegen.Optimization `args:"name=o" usage:"optimization level (default: speed)"`,
	emit_llvm:    bool `usage:"write textual LLVM IR instead of an executable"`,
	emit_ir:      bool `usage:"write the tsnc IR dump instead of an executable"`,
	target:       target.Target `usage:"target platform, for example linux_amd64 (default: host)"`,
	jobs:         int `args:"name=j" usage:"worker threads (default: number of cores)"`,
}

main :: proc() {
	options := Options {
		optimization = .speed,
		target       = target.HOST,
		jobs         = os.get_processor_core_count(),
	}
	flags.parse_or_exit(&options, os.args, .Odin)

	// stderr only: stdout belongs to the compiled program under `tsnc run`.
	// core:flags accepts every Target value, and a declared target may have no SPECS row yet.
	if !target.supported(options.target) {
		fmt.eprintfln("target %v is not supported yet", options.target)
		os.exit(1)
	}

	fmt.eprintfln("%#v", options)
	fmt.eprintfln("tsnc %v: not implemented", options.command)
	os.exit(1)
}
