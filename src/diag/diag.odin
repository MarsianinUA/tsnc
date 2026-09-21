/*
Compile errors as values. A phase reports a Diagnostic (a code, a span and up to MAX_ARGS
arguments) and keeps going; driver collects the diagnostics of every phase, sorts them with sort,
and main prints each with render:

	src/main.ts:3:1: error[T2001]: `var` is not supported
	  hint: use `let`, or `const` for a variable that is never reassigned

Format rules (requirements 5):
- The position is the start of the span. Lines and columns are 1-based, and a column counts UTF-16
  code units from the start of the line, as in tsc and VS Code; source.position computes them.
- Every code has a number, a text and a hint that says how to rewrite the code. Numbers go by
  range: T1xxx syntax, T2xxx constructs outside the subset, T3xxx types, T4xxx names, modules and
  imports.
  Tests and users refer to the numbers, so a number never changes and is never reused, even after
  its code is removed.
- Texts and hints are in English, start with a lowercase letter, have no trailing period and put
  code in backticks. {0} and {1} in them stand for the diagnostic's arguments.
- New codes are added only here, in codes.odin, and so are the texts of the constructs that share
  Unsupported_Syntax (Construct).
*/
package diag

import "core:io"
import "core:slice"

import "../source"

MAX_ARGS :: 2

Diagnostic :: struct {
	code: Code,
	span: source.Span,
	// Borrowed from the source text or the reporting phase's arena. A code with one argument sets
	// it by index: `args = {0 = name}`.
	args: [MAX_ARGS]string,
}

// sort is stable, so the order stays deterministic as long as the caller collects the diagnostics
// in a fixed order, whatever the number of threads.
sort :: proc(diagnostics: []Diagnostic) {
	slice.stable_sort_by(diagnostics, prints_before)
}

render :: proc(w: io.Writer, files: []source.File, d: Diagnostic) -> io.Error {
	file := files[d.span.file]
	position := source.position(file, d.span.start)
	row := REGISTRY[d.code]

	io.write_string(w, file.path) or_return
	io.write_byte(w, ':') or_return
	io.write_int(w, int(position.line)) or_return
	io.write_byte(w, ':') or_return
	io.write_int(w, int(position.column)) or_return
	io.write_string(w, ": error[T") or_return
	io.write_int(w, int(row.number)) or_return
	io.write_string(w, "]: ") or_return
	write_template(w, row.text, d.args) or_return
	io.write_string(w, "\n  hint: ") or_return
	write_template(w, row.hint, d.args) or_return
	return io.write_byte(w, '\n')
}

@(private)
prints_before :: proc(a, b: Diagnostic) -> bool {
	if a.span.file != b.span.file {
		return a.span.file < b.span.file
	}
	if a.span.start != b.span.start {
		return a.span.start < b.span.start
	}
	// The number, not the enum position: the enum order is free.
	return REGISTRY[a.code].number < REGISTRY[b.code].number
}

// write_template writes template with every {i} replaced by args[i]. Any other brace is literal.
@(private)
write_template :: proc(w: io.Writer, template: string, args: [MAX_ARGS]string) -> io.Error {
	literal_start := 0
	for i := 0; i + 2 < len(template); i += 1 {
		digit := template[i + 1]
		is_digit := '0' <= digit && digit <= '9'
		is_placeholder := template[i] == '{' && is_digit && template[i + 2] == '}'
		if !is_placeholder {
			continue
		}

		index := int(digit - '0')
		assert(index < MAX_ARGS, "a registry text refers to an argument past MAX_ARGS")
		io.write_string(w, template[literal_start:i]) or_return
		io.write_string(w, args[index]) or_return
		i += 2
		literal_start = i + 1
	}
	_, err := io.write_string(w, template[literal_start:])
	return err
}
