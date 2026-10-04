package main

import "core:flags"
import "core:fmt"
import "core:os"

import "codegen"
import "driver"
import "link"
import "target"

// Each job is a thread, and a count past the cores of any machine is a typo.
MAX_JOBS :: 256

// Command values are lowercase because core:flags matches them against the command line by exact
// name: `tsnc build`. codegen.Optimization, link.Sanitizer and target.Target follow the same rule
// for `-o:`, `-sanitize:` and `-target:`.
Command :: enum {
	build,
	run,
	check,
}

Flags :: struct {
	command:      Command `args:"pos=0,required" usage:"build, run or check"`,
	input:        string `args:"pos=1,required" usage:"entry .ts file"`,
	output:       string `args:"name=out" usage:"output path"`,
	optimization: codegen.Optimization `args:"name=o" usage:"optimization level (default: speed)"`,
	emit_llvm:    bool `usage:"write textual LLVM IR instead of an executable"`,
	emit_ir:      bool `usage:"write the tsnc IR dump instead of an executable"`,
	target:       target.Target `usage:"target platform, for example linux_amd64 (default: host)"`,
	jobs:         int `args:"name=j" usage:"worker threads (default: number of cores)"`,
	sanitize:     link.Sanitizer `usage:"link the runtime built with -sanitize:address (default: none)"`,
}

main :: proc() {
	given := Flags {
		optimization = .speed,
		target       = target.HOST,
		jobs         = clamp(os.get_processor_core_count(), 1, MAX_JOBS),
	}
	flags.parse_or_exit(&given, command_line(), .Odin)

	// core:flags accepts every Target value, and a declared target may have no SPECS row yet.
	if !target.supported(given.target) {
		fmt.eprintfln("target %v is not supported yet", given.target)
		os.exit(1)
	}
	if given.jobs < 1 || given.jobs > MAX_JOBS {
		fmt.eprintfln("-j:%d is not a thread count\n  hint: pass 1 to %d", given.jobs, MAX_JOBS)
		os.exit(1)
	}
	options, refusal := options_of(given)
	if refusal != "" {
		fmt.eprintfln("tsnc: %s", refusal)
		os.exit(1)
	}

	// One file per command: check.odin, build.odin and run.odin, with report.odin holding what all
	// three print. No default case, so a command added later fails the build here until it is
	// handled.
	switch given.command {
	case .check:
		os.exit(check(options))
	case .build:
		os.exit(build(options))
	case .run:
		os.exit(run(options))
	}
}

// options_of refuses a command line that contradicts itself, with a message and a hint the way
// error_text words a failure of driver.
@(private = "file")
options_of :: proc(given: Flags) -> (options: driver.Options, refusal: string) {
	options = {
		input        = given.input,
		output       = given.output,
		optimization = given.optimization,
		target       = given.target,
		jobs         = given.jobs,
		sanitize     = given.sanitize,
	}
	switch {
	case given.emit_llvm && given.emit_ir:
		return {}, "-emit-llvm and -emit-ir name two different files\n  hint: pass one of them"
	case given.emit_llvm:
		options.artifact = .LLVM_IR
	case given.emit_ir:
		options.artifact = .IR_Dump
	case:
		options.artifact = .Executable
	}
	if given.command == .run && options.artifact != .Executable {
		return {}, NOTHING_TO_RUN
	}
	return options, ""
}

@(private = "file")
NOTHING_TO_RUN :: "tsnc run builds a program and runs it, while -emit-llvm and -emit-ir write a file\n  hint: `tsnc build` writes those"

// command_line is the arguments tsnc was started with, in UTF-8. os.args is the narrow argv of the C
// runtime, which Windows fills in the ANSI code page, so a path with Cyrillic letters in it named no
// file. core:os reads the wide command line for a process info instead, and only when asked for both
// fields at once. The arguments live as long as the process, like os.args.
@(private = "file")
command_line :: proc() -> []string {
	when ODIN_OS == .Windows {
		info, _ := os.current_process_info({.Command_Line, .Command_Args}, context.allocator)
		if .Command_Args in info.fields {
			return info.command_args
		}
	}
	return os.args
}
