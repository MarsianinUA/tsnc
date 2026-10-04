/*
The negative mode: every program in tests/negative/ must fail to compile in exactly the way its own
header says it does. docs/development.md#negative-tests has the `// expect:` line and how the
expectations are compared.

The expectations are the whole truth about a program: a diagnostic the header does not mention
fails it exactly as a missing one does, or parser recovery could start emitting noise and no test
would notice. For the same reason a program with no expectation at all fails, and so does a
malformed `// expect:` line: skipping either would leave a test that proves nothing.

The mode runs `tsnc build` with the compiler the build left in dist/, instead of calling driver in
process, so that the rendered message, the code number, the choice of stderr and the exit code are
covered as well as the diagnostics themselves. `tsnc check -j:8` must print the same bytes as
`tsnc build -j:1`: check lists everything build refuses (requirements 2.3), and one checker over
the program and one per partition find the same mistakes. The header is compared with the build.
*/
package main

import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/target"

// NEGATIVE_CORPUS is relative to the current directory, as the compiler path in runner.odin is:
// the runner is started from the repository root.
NEGATIVE_CORPUS :: "tests/negative"

EXPECT_PREFIX :: "// expect:"
EXPECT_EXAMPLE :: "// expect: T2001 5:1"
EXPECT_FULL_EXAMPLE :: `// expect: T4009 modules/relay.ts:1:10 "does not export"`

// MARKER stands between the position of a rendered diagnostic and its code:
//
//	tests/negative/var.ts:5:1: error[T2001]: `var` is not supported
MARKER :: ": error[T"

// HINT_PREFIX opens the second line of every rendered diagnostic.
HINT_PREFIX :: "  hint: "

// Site is where a diagnostic stands and which one it is, the part an expectation always names.
@(private = "file")
Site :: struct {
	file:   string, // as the compiler prints it: tests/negative/<name>
	number: int, // the code as diag prints it, without the leading T
	line:   int,
	column: int,
}

@(private = "file")
Expectation :: struct {
	site: Site,
	text: string, // "" when the header quotes nothing
}

@(private = "file")
Printed :: struct {
	site:    Site,
	message: string,
	hint:    string,
}

// negative reports every mismatch instead of stopping at the first, so that one CI log shows all of
// them.
negative :: proc(jobs: int) -> (passed: bool) {
	compiler := compiler_path(.negative) or_return
	paths := corpus_paths(.negative, NEGATIVE_CORPUS) or_return
	dist := dist_directory(.negative) or_return

	template := Job {
		mode     = .negative,
		compiler = compiler,
		dist     = dist,
	}
	diagnostics: int
	diagnostics, passed = run_programs(template, paths, jobs, negative_program)
	if passed {
		fmt.printfln("negative: ok (%d programs, %d diagnostics)", len(paths), diagnostics)
	}
	return passed
}

// negative_program answers how many diagnostics the compiler printed, for the summary line. The
// program keeps its relative path: the compiler inherits this directory, and the path is what the
// compiler prints and an expectation names.
@(private = "file")
negative_program :: proc(job: Job, path: string) -> (printed: int, ok: bool) {
	text, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.sbprintfln(job.report, "negative: %s: read: %v", path, read_err)
		return 0, false
	}
	want, want_ok := expectations(job, path, string(text))

	// A build with a diagnostic writes nothing. The artifact is named for a program that stops
	// failing: it links, and the exit code below reports it.
	suffix := target.SPECS[target.HOST].executable_suffix
	artifact := fmt.tprintf("negative-%s%s", strings.trim_suffix(os.base(path), ".ts"), suffix)
	output, join_err := os.join_path({job.dist, artifact}, context.temp_allocator)
	if join_err != nil {
		fmt.sbprintfln(job.report, "negative: %s: path of %s: %v", path, artifact, join_err)
		return 0, false
	}
	out := fmt.tprintf("-out:%s", output)
	one := []string{job.compiler, "build", path, out, "-j:1"}
	eight := []string{job.compiler, "check", path, "-j:8"}
	built := execute(job, path, "tsnc build", one) or_return
	checked := execute(job, path, "tsnc check", eight) or_return
	got, got_ok := diagnostics_of(job, path, built.stderr)

	ok = want_ok && got_ok
	if checked.stderr != built.stderr ||
	   checked.stdout != built.stdout ||
	   checked.code != built.code {
		fmt.sbprintfln(
			job.report,
			"negative: %s: check -j:8 prints otherwise than build -j:1",
			path,
		)
		fmt.sbprintfln(job.report, "build -j:1 answered %d:\n%s", built.code, built.stderr)
		fmt.sbprintfln(job.report, "check -j:8 answered %d:\n%s", checked.code, checked.stderr)
		ok = false
	}
	if built.code != 1 {
		// `tsnc build` answers 1 for a program with any diagnostic and 0 for one it built, so a
		// negative test always expects 1. A crash lands here too, with whatever the OS reports.
		fmt.sbprintfln(job.report, "negative: %s: exit code: got %d, want 1", path, built.code)
		ok = false
	}
	if built.stdout != "" {
		// The compiler writes to stderr alone, so that the diagnostics of a build never mix with
		// the output of a program under `tsnc run`.
		fmt.sbprintfln(
			job.report,
			"negative: %s: stdout: got %q, want nothing",
			path,
			built.stdout,
		)
		ok = false
	}

	// Compared by position, so that a missing, an extra and a wrong diagnostic all read alike. A
	// header that did not parse has already been reported and is not worth comparing against.
	if want_ok {
		for index in 0 ..< max(len(want), len(got)) {
			if !same_diagnostic(job, path, index, want, got) {
				ok = false
			}
		}
	}
	return len(got), ok
}

// same_diagnostic names what differs at one index, and a text that is not there gets the message
// and the hint it was looked for in.
@(private = "file")
same_diagnostic :: proc(
	job: Job,
	path: string,
	index: int,
	want: []Expectation,
	got: []Printed,
) -> bool {
	if index < len(want) && index < len(got) && want[index].site == got[index].site {
		text := want[index].text
		if strings.contains(got[index].message, text) || strings.contains(got[index].hint, text) {
			return true
		}
		fmt.sbprintfln(
			job.report,
			"negative: %s: diagnostic %d: %s: neither the message nor the hint holds \"%s\"",
			path,
			index + 1,
			describe(path, got[index].site),
			text,
		)
		fmt.sbprintfln(job.report, "  message: %s", got[index].message)
		fmt.sbprintfln(job.report, "  hint: %s", got[index].hint)
		return false
	}

	wanted := "nothing"
	if index < len(want) {
		wanted = describe(path, want[index].site)
		if want[index].text != "" {
			wanted = fmt.tprintf("%s \"%s\"", wanted, want[index].text)
		}
	}
	found := "nothing"
	if index < len(got) {
		found = describe(path, got[index].site)
	}
	fmt.sbprintfln(
		job.report,
		"negative: %s: diagnostic %d: got %s, want %s",
		path,
		index + 1,
		found,
		wanted,
	)
	return false
}

@(private = "file")
expectations :: proc(job: Job, path, text: string) -> (want: []Expectation, ok: bool) {
	list := make([dynamic]Expectation, context.temp_allocator)
	ok = true

	for line, index in header_lines(text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, EXPECT_PREFIX) {
			continue
		}
		body := strings.trim_space(trimmed[len(EXPECT_PREFIX):])
		expected, line_ok := parse_expectation(path, body)
		if !line_ok {
			fmt.sbprintfln(job.report, "negative: %s:%d: cannot read %q", path, index + 1, trimmed)
			fmt.sbprintfln(job.report, "  an expectation reads: %s", EXPECT_EXAMPLE)
			fmt.sbprintfln(job.report, "  or with a file and a text: %s", EXPECT_FULL_EXAMPLE)
			ok = false
			continue
		}
		append(&list, expected)
	}

	if ok && len(list) == 0 {
		fmt.sbprintfln(job.report, "negative: %s: the header expects nothing", path)
		fmt.sbprintfln(
			job.report,
			"  a negative test names every diagnostic it expects: %s",
			EXPECT_EXAMPLE,
		)
		ok = false
	}
	return list[:], ok
}

// parse_expectation reads the body of an expectation, `T4009 modules/relay.ts:1:10 "text"`, where
// the file and the text may be left out.
@(private = "file")
parse_expectation :: proc(program, body: string) -> (expected: Expectation, ok: bool) {
	code, _, after_code := strings.partition(body, " ")
	position, _, after_position := strings.partition(strings.trim_left_space(after_code), " ")
	quoted := strings.trim_space(after_position)

	// The range is the one diag guarantees, so that a typo such as T20 cannot pass for a code.
	if !strings.has_prefix(code, "T") {
		return {}, false
	}
	number := parse_number(code[1:]) or_return
	if number < 1000 || number > 9999 {
		return {}, false
	}

	file, line, column := parse_position(position) or_return
	expected.site = {
		file   = program,
		number = number,
		line   = line,
		column = column,
	}
	if file != "" {
		expected.site.file = fmt.tprintf("%s/%s", NEGATIVE_CORPUS, file)
	}

	if quoted != "" {
		// The quotes are the first and the last byte, and an empty text would match anything.
		if len(quoted) < 3 || quoted[0] != '"' || quoted[len(quoted) - 1] != '"' {
			return {}, false
		}
		expected.text = quoted[1:len(quoted) - 1]
	}
	return expected, true
}

// diagnostics_of reads what `tsnc build` printed. Every diagnostic is two lines, the error and its
// hint. A line that is neither is the compiler saying something an expectation cannot express,
// such as an entry file it could not read, and it fails the program rather than passing unseen.
@(private = "file")
diagnostics_of :: proc(job: Job, path, text: string) -> (got: []Printed, ok: bool) {
	list := make([dynamic]Printed, context.temp_allocator)
	ok = true

	rest := text
	awaits_hint := false
	for line in strings.split_lines_iterator(&rest) {
		if line == "" {
			continue
		}
		if awaits_hint && strings.has_prefix(line, HINT_PREFIX) {
			list[len(list) - 1].hint = line[len(HINT_PREFIX):]
			awaits_hint = false
			continue
		}
		printed, line_ok := parse_diagnostic(line)
		awaits_hint = line_ok
		if !line_ok {
			fmt.sbprintfln(
				job.report,
				"negative: %s: cannot read the compiler output %q",
				path,
				line,
			)
			ok = false
			continue
		}
		append(&list, printed)
	}
	return list[:], ok
}

@(private = "file")
parse_diagnostic :: proc(text: string) -> (printed: Printed, ok: bool) {
	marker := strings.index(text, MARKER)
	if marker < 0 {
		return {}, false
	}
	file, line, column := parse_position(text[:marker]) or_return
	if file == "" {
		return {}, false
	}
	printed.site = {
		file   = file,
		line   = line,
		column = column,
	}

	// After the marker stand the number, `]: ` and the message.
	tail := text[marker + len(MARKER):]
	close := strings.index_byte(tail, ']')
	if close < 0 || !strings.has_prefix(tail[close:], "]: ") {
		return {}, false
	}
	printed.site.number = parse_number(tail[:close]) or_return
	printed.message = tail[close + len("]: "):]
	return printed, true
}

// parse_position reads `file:line:column` from the right, so that a path holding a colon of its own
// cannot throw it off. The file is "" when the text is `line:column` alone.
@(private = "file")
parse_position :: proc(text: string) -> (file: string, line, column: int, ok: bool) {
	column_colon := strings.last_index_byte(text, ':')
	if column_colon < 0 {
		return
	}
	head := text[:column_colon]
	if line_colon := strings.last_index_byte(head, ':'); line_colon >= 0 {
		file = head[:line_colon]
		head = head[line_colon + 1:]
		if file == "" {
			return
		}
	}
	line = parse_number(head) or_return
	column = parse_number(text[column_colon + 1:]) or_return
	return file, line, column, line >= 1 && column >= 1
}

// describe spells a diagnostic as a header does: the file only when it is not the program itself,
// and relative to the corpus.
@(private = "file")
describe :: proc(program: string, site: Site) -> string {
	if site.file == program {
		return fmt.tprintf("T%d %d:%d", site.number, site.line, site.column)
	}
	file := strings.trim_prefix(site.file, NEGATIVE_CORPUS + "/")
	return fmt.tprintf("T%d %s:%d:%d", site.number, file, site.line, site.column)
}
