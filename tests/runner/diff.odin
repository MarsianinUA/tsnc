/*
The diff mode: every program in tests/diff/src must print what Node prints, byte for byte, with
nothing normalized on the way, neither line endings nor encoding, because a difference in either is
exactly the kind of thing this test exists to find. docs/development.md#differential-tests has the
layout of tests/diff, the gate and the two header lines.
*/
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// DIFF_PROJECT and DIFF_CORPUS are relative to the current directory, as the compiler path in
// runner.odin is: the runner is started from the repository root.
DIFF_PROJECT :: "tests/diff"
DIFF_CORPUS :: DIFF_PROJECT + "/src"

// TSC is the launcher npm installs from the project's package.json: a JavaScript file that loads
// the compiler, so one command starts it on every system, and TSC_INSTALL puts it there.
TSC :: DIFF_PROJECT + "/node_modules/typescript/bin/tsc"
TSC_INSTALL :: "npm ci --prefix " + DIFF_PROJECT

// NODE is named without a path, so the OS finds it the way it finds any program. Requirements 10
// pin Node 24, which runs a .ts file with no flags and is what makes it a reference at all.
NODE :: "node"

// gate is a precondition rather than a test of its own: a program that does not type-check is a
// broken corpus, and tsc names every file and line it objects to, so one run shows all of them.
gate :: proc(job: Job) -> (ok: bool) {
	if !os.is_file(TSC) {
		fmt.sbprintfln(job.report, "%v: %s is missing", job.mode, TSC)
		fmt.sbprintfln(
			job.report,
			"the gate needs TypeScript, installed once from %s/package.json:",
			DIFF_PROJECT,
		)
		fmt.sbprintfln(job.report, "  %s", TSC_INSTALL)
		return false
	}

	command := []string{NODE, TSC, "--noEmit", "--strict", "-p", DIFF_PROJECT}
	output := execute(job, DIFF_PROJECT, "the gate", command) or_return
	if output.code == 0 {
		return true
	}

	fmt.sbprintfln(
		job.report,
		"%v: the gate rejected the corpus: tsc --noEmit --strict -p %s",
		job.mode,
		DIFF_PROJECT,
	)
	// tsc writes its diagnostics to stdout; stderr carries whatever stopped it from starting.
	fmt.sbprint(job.report, output.stdout)
	fmt.sbprint(job.report, output.stderr)
	return false
}

diff_program :: proc(job: Job, path: string) -> (count: int, ok: bool) {
	header := read_header(job, path) or_return
	environments := environments_for(job, path, header.settings) or_return
	node := slice.concatenate([][]string{{NODE, path}, header.arguments}, context.temp_allocator)
	want := execute(job, path, "node", node, environments.plain) or_return
	if want.code != 0 && !own_exit_code(want.code) {
		fmt.sbprintfln(
			job.report,
			"diff: %s: exit code %d: a corpus program exits with 0 or %d..%d",
			path,
			want.code,
			SIGNAL_MAX + 1,
			EXIT_MAX,
		)
		return 0, false
	}
	return 0, compare_builds(job, path, want, header.arguments, environments)
}

@(private = "file")
Header :: struct {
	settings:  []string, // nil when the header sets nothing
	arguments: []string,
}

@(private = "file")
read_header :: proc(job: Job, path: string) -> (header: Header, ok: bool) {
	ENV :: "// env: "
	ARGS :: "// args: "
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.sbprintfln(job.report, "diff: read %s: %v", path, read_err)
		return {}, false
	}

	// A header spelled another way, or with nothing after it, would run the program without it,
	// and the two runs could still agree; such a line is refused rather than read as prose.
	has_env, has_args: bool
	for line in header_lines(string(data)) {
		if !names_header(line) {
			continue
		}
		well_formed := false
		switch {
		case strings.has_prefix(line, ENV) && !has_env:
			header.settings = strings.fields(line[len(ENV):], context.temp_allocator)
			has_env = true
			well_formed = len(header.settings) > 0
		case strings.has_prefix(line, ARGS) && !has_args:
			header.arguments = strings.fields(line[len(ARGS):], context.temp_allocator)
			has_args = true
			well_formed = len(header.arguments) > 0
		case strings.has_prefix(line, ENV), strings.has_prefix(line, ARGS):
			fmt.sbprintfln(job.report, "diff: %s: a second header line %q", path, line)
			return {}, false
		}
		if !well_formed {
			fmt.sbprintfln(
				job.report,
				"diff: %s: a header line %q lists nothing or is misspelled",
				path,
				line,
			)
			return {}, false
		}
	}
	return header, true
}

// names_header says whether a line is a comment that starts as a header does, `env:` or `args:`
// after the slashes, however it is spaced; read_header takes only the one spelling.
@(private = "file")
names_header :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	if !strings.has_prefix(trimmed, "//") {
		return false
	}
	rest := strings.trim_left_space(trimmed[2:])
	return strings.has_prefix(rest, "env:") || strings.has_prefix(rest, "args:")
}
