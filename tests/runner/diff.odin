/*
The diff mode: every program in tests/diff/ must print what Node prints, byte for byte.

A corpus program is a whole program, not a fragment, and it carries no expected output of its own.
The expectation is Node: the mode runs `node <program>`, then builds the same file with `tsnc build`
and runs what came out, and compares stdout, stderr and the exit code (compare.odin). Nothing is
normalized on the way, neither line endings nor encoding, because a difference in either is exactly
the kind of thing this test exists to find.

Before any of that the corpus passes a gate: `tsc --noEmit --strict` over tests/diff/tsconfig.json,
so that a corpus program is TypeScript the real compiler accepts and not merely something tsnc
happens to swallow (requirements 10). The gate runs once for the whole corpus and is a precondition
rather than a test of its own: a program that does not type-check is a broken corpus, and tsc names
every file and line it objects to, so one run still shows all of them. It covers the programs of
tests/expect as well, which the expect mode runs it for.

tests/diff is an npm project, laid out the way one is: package.json, package-lock.json and
tsconfig.json at the top, the node_modules npm unpacks from them beside those, and the programs
under src/. The manifests sit above the programs rather than elsewhere in tests/, because Node reads
`"type": "module"` from the nearest package.json and it has to be an ancestor of the programs for an
import in one of them to run at all.

The walk takes only the `.ts` files directly in tests/diff/src, the way the negative corpus does:
the modules under tests/diff/src/modules/ are there to be imported and are never run as programs of
their own.

A program may start with two header lines, each at most once and in either order, and both runs
follow them. `// env: NAME=value ...` runs it in the runner's environment with those variables set,
an empty value included; colors.ts sets FORCE_COLOR that way, which is the one way to see colors
through a pipe. `// args: a b ...` passes those arguments after the program, split on whitespace
with no quoting; process-argv.ts reads them.
*/
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../../src/link"

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

// A death by signal and an exit read the same on POSIX: os.Process_State puts the signal's number
// where the code goes and clears success for both, and on Windows a crash is an NTSTATUS for a
// code. So the code is all there is to compare, and a corpus program keeps its own code above
// every signal number, where a crash can never pass for the right answer.
SIGNAL_MAX :: 64

// diff reports every mismatch instead of stopping at the first, so that one CI log shows all of
// them.
diff :: proc(sanitizer: link.Sanitizer) -> (passed: bool) {
	compiler := compiler_path("diff") or_return
	names := corpus_names(.diff, DIFF_CORPUS) or_return
	gate(.diff) or_return
	dist := dist_directory(.diff) or_return

	passed = true
	for name in names {
		if !diff_program(compiler, dist, name, sanitizer) {
			passed = false
		}
	}
	if passed {
		fmt.printfln("diff: ok (%d programs, %d builds)", len(names), len(names) * len(LEVELS))
	}
	return passed
}

gate :: proc(mode: Mode) -> (ok: bool) {
	if !os.is_file(TSC) {
		fmt.eprintfln("%v: %s is missing", mode, TSC)
		fmt.eprintfln(
			"the gate needs TypeScript, installed once from %s/package.json:",
			DIFF_PROJECT,
		)
		fmt.eprintfln("  %s", TSC_INSTALL)
		return false
	}

	state, stdout, stderr, err := os.process_exec(
		{command = {NODE, TSC, "--noEmit", "--strict", "-p", DIFF_PROJECT}},
		context.temp_allocator,
	)
	if err != nil {
		fmt.eprintfln("%v: gate: run %s: %v", mode, NODE, err)
		fmt.eprintln("the corpus needs Node 24: it runs the reference and hosts the gate")
		return false
	}
	if state.exit_code == 0 {
		return true
	}

	fmt.eprintfln(
		"%v: the gate rejected the corpus: tsc --noEmit --strict -p %s",
		mode,
		DIFF_PROJECT,
	)
	// tsc writes its diagnostics to stdout; stderr carries whatever stopped it from starting.
	fmt.eprint(string(stdout))
	fmt.eprint(string(stderr))
	return false
}

@(private = "file")
diff_program :: proc(compiler, dist, name: string, sanitizer: link.Sanitizer) -> (ok: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	path := fmt.tprintf("%s/%s", DIFF_CORPUS, name)
	header := read_header(path) or_return
	node := slice.concatenate([][]string{{NODE, path}, header.arguments}, context.temp_allocator)
	want := execute(.diff, path, "node", node, header.environment) or_return
	if want.code >= 1 && want.code <= SIGNAL_MAX {
		fmt.eprintfln(
			"diff: %s: exit code %d is also a signal's number; a corpus program exits with 0 or %d..125",
			path,
			want.code,
			SIGNAL_MAX + 1,
		)
		return false
	}
	return compare_builds(
		.diff,
		compiler,
		dist,
		path,
		sanitizer,
		want,
		header.arguments,
		header.environment,
	)
}

@(private = "file")
Header :: struct {
	environment: []string, // nil keeps the runner's own
	arguments:   []string,
}

@(private = "file")
read_header :: proc(path: string) -> (header: Header, ok: bool) {
	ENV :: "// env: "
	ARGS :: "// args: "
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("diff: read %s: %v", path, read_err)
		return {}, false
	}

	// A header spelled another way, or with nothing after it, would run the program without it,
	// and the two runs could still agree; such a line is refused rather than read as prose.
	settings: []string
	has_env, has_args: bool
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !names_header(line) {
			break
		}
		well_formed := false
		switch {
		case strings.has_prefix(line, ENV) && !has_env:
			settings = strings.fields(line[len(ENV):], context.temp_allocator)
			has_env = true
			well_formed = len(settings) > 0
		case strings.has_prefix(line, ARGS) && !has_args:
			header.arguments = strings.fields(line[len(ARGS):], context.temp_allocator)
			has_args = true
			well_formed = len(header.arguments) > 0
		case strings.has_prefix(line, ENV), strings.has_prefix(line, ARGS):
			fmt.eprintfln("diff: %s: a second header line %q", path, line)
			return {}, false
		}
		if !well_formed {
			fmt.eprintfln("diff: %s: a header line %q lists nothing or is misspelled", path, line)
			return {}, false
		}
	}
	if has_env {
		header.environment = environment_with(path, settings) or_return
	}
	return header, true
}

// names_header says whether a line is a comment that starts as a header does, `env:` or `args:`
// after the slashes, however it is spaced; read_header takes only the one spelling.
@(private = "file")
names_header :: proc(line: string) -> bool {
	if !strings.has_prefix(line, "//") {
		return false
	}
	rest := strings.trim_left_space(line[2:])
	return strings.has_prefix(rest, "env:") || strings.has_prefix(rest, "args:")
}

// environment_with lets a name the program sets replace the runner's own, whose case Windows
// ignores.
@(private = "file")
environment_with :: proc(path: string, settings: []string) -> (environment: []string, ok: bool) {
	inherited, env_err := os.environ(context.temp_allocator)
	if env_err != nil {
		fmt.eprintfln("diff: %s: read the environment: %v", path, env_err)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	for entry in inherited {
		name, _, _ := strings.partition(entry, "=")
		if !sets(settings, name) {
			append(&list, entry)
		}
	}
	append(&list, ..settings)
	return list[:], true
}

@(private = "file")
sets :: proc(settings: []string, name: string) -> bool {
	for setting in settings {
		set, _, _ := strings.partition(setting, "=")
		same := strings.equal_fold(set, name) if ODIN_OS == .Windows else set == name
		if same {
			return true
		}
	}
	return false
}
