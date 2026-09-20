package check_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/ast"
import "../../src/bind"
import "../../src/check"
import "../../src/diag"
import "../../src/parse"
import "../../src/program"
import "../../src/source"

// LIB_TEXT is the real lib.d.ts, embedded the way driver embeds it. A stub would drift away from
// the file the compiler ships, and one of the things these tests have to prove is that the real one
// types without a single diagnostic.
//
// Nothing here goes through driver: driver owns Options, which names an optimization level, so it
// links codegen and llvm, and these tests would then need LLVM-C.dll on PATH to run at all.
LIB_TEXT :: #load("../../src/lib/lib.d.ts", string)

// LIB is the lib module, File_ID zero of every program, as program.LIB says.
LIB :: source.File_ID(0)

// MAIN is the File_ID of the first source a test passes, the one it usually asks about.
MAIN :: source.File_ID(1)

// Error is a diagnostic the way a user reads it: its code, and the 1-based line and column where it
// starts.
Error :: struct {
	code:   diag.Code,
	line:   i32,
	column: i32,
}

Checked :: struct {
	program:     program.Program,
	result:      check.Check_Result,
	diagnostics: []diag.Diagnostic, // check's own, in print order
	errors:      []Error, // the same, as a test reads them
}

// check_sources parses and binds the lib file as module zero and each source as the next File_ID,
// builds the program, and checks the files that partition names. Everything lives in the temp
// allocator, which the test runner frees before each test, so a test frees nothing.
check_sources :: proc(
	t: ^testing.T,
	sources: []string,
	partition: []source.File_ID,
	loc := #caller_location,
) -> Checked {
	texts := make([]string, len(sources) + 1, context.temp_allocator)
	texts[0] = LIB_TEXT
	copy(texts[1:], sources)

	count := len(texts)
	files := make([]source.File, count, context.temp_allocator)
	trees := make([]ast.File_AST, count, context.temp_allocator)
	bound := make([]bind.Bound_File, count, context.temp_allocator)
	imports := make([][]program.Import_Edge, count, context.temp_allocator)

	for text, i in texts {
		path := "lib.d.ts" if i == 0 else fmt.tprintf("m%d.ts", i)
		files[i] = source.make_file(path, text, context.temp_allocator)

		tree, parse_diagnostics := parse.parse_file(
			text,
			source.File_ID(i),
			context.temp_allocator,
		)
		trees[i] = tree
		bound[i], _ = bind.bind_file(&trees[i], context.temp_allocator)

		// A test says what check does, so anything the layers under it report is a broken test.
		testing.expectf(
			t,
			len(parse_diagnostics) == 0,
			"%s: parse %v",
			path,
			errors_of(files, parse_diagnostics),
			loc = loc,
		)
	}

	prog, graph_diagnostics := program.build(files, trees, bound, imports, context.temp_allocator)
	testing.expectf(t, len(graph_diagnostics) == 0, "program %v", graph_diagnostics, loc = loc)

	result, diagnostics := check.check(&prog, partition, context.temp_allocator)
	diag.sort(diagnostics)

	checked := Checked {
		program     = prog,
		result      = result,
		diagnostics = diagnostics,
		errors      = errors_of(files, diagnostics),
	}
	check_typed(t, checked, loc)
	return checked
}

// check_text checks one source, with the lib as module zero and outside the partition, which is
// what a checker over a partition of a real program sees.
check_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Checked {
	one := [1]string{text}
	partition := [1]source.File_ID{MAIN}
	return check_sources(t, one[:], partition[:], loc)
}

// expect_checked checks a source that has to type without a single diagnostic.
expect_checked :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Checked {
	c := check_text(t, text, loc)
	testing.expectf(t, len(c.errors) == 0, "%q: %v", text, c.errors, loc = loc)
	return c
}

// expect_errors checks a source and compares the diagnostics, in print order, one for one.
expect_errors :: proc(
	t: ^testing.T,
	text: string,
	expected: []Error,
	loc := #caller_location,
) -> Checked {
	c := check_text(t, text, loc)
	testing.expectf(
		t,
		slice.equal(c.errors, expected),
		"%q: errors %v, want %v",
		text,
		c.errors,
		expected,
		loc = loc,
	)
	return c
}

// Reading the result.

// declared_text is the type check gave the declaration of that name, printed. It is what a test
// about inference asks for.
//
// A name holds one value and one type, and the lib file uses both of `String` and `Math`, so this
// asks for the value: a type declaration is T3.3 and has nothing to print yet.
declared_text :: proc(c: Checked, name: string, file := MAIN) -> string {
	typed, ok := check.typed_file(c.result, file)
	if !ok {
		return "<not in the partition>"
	}
	for symbol in c.program.bound[file].symbols[1:] {
		is_value := .Value in bind.meanings(symbol.kind)
		if is_value && symbol.name.text == name && symbol.declaration != ast.NO_NODE {
			return type_text(c, typed.node_types[symbol.declaration])
		}
	}
	return "<no such name>"
}

// use_text is the type of one use of a name: the occurrence-th ast.Ident with that text, counted
// from the start of the file.
use_text :: proc(c: Checked, name: string, occurrence := 0, file := MAIN) -> string {
	typed, ok := check.typed_file(c.result, file)
	if !ok {
		return "<not in the partition>"
	}
	seen := 0
	for node, id in c.program.trees[file].nodes {
		identifier, is_ident := node.variant.(ast.Ident)
		if !is_ident || identifier.name != name {
			continue
		}
		if seen == occurrence {
			return type_text(c, typed.node_types[id])
		}
		seen += 1
	}
	return "<no such use>"
}

// use_declaration is what check decided a use of a name refers to, which is bind's answer for a
// name the file declares and check's own for a name of the lib module.
use_declaration :: proc(
	c: Checked,
	name: string,
	occurrence := 0,
	file := MAIN,
) -> check.Symbol_Ref {
	typed, ok := check.typed_file(c.result, file)
	if !ok {
		return {}
	}
	seen := 0
	for node, id in c.program.trees[file].nodes {
		identifier, is_ident := node.variant.(ast.Ident)
		if !is_ident || identifier.name != name {
			continue
		}
		if seen == occurrence {
			return typed.node_symbols[id]
		}
		seen += 1
	}
	return {}
}

// rendered is one diagnostic the way main prints it, error line and hint, for the tests that have
// to read the hint rather than only the code.
rendered :: proc(c: Checked, index: int) -> string {
	if index >= len(c.diagnostics) {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	_ = diag.render(strings.to_writer(&b), c.program.files, c.diagnostics[index])
	return strings.to_string(b)
}

type_text :: proc(c: Checked, id: check.Type_ID) -> string {
	return check.type_text(c.result.types, id, context.temp_allocator)
}

// check_typed asserts what every Check_Result has to hold, whatever program it came from. Every
// test runs it, the way the bind suite runs check_bound.
check_typed :: proc(t: ^testing.T, c: Checked, loc := #caller_location) {
	testing.expectf(
		t,
		len(c.result.types) >= len(check.Basic_Kind),
		"the table has %d rows, too few for the types with no parts",
		len(c.result.types),
		loc = loc,
	)

	for typed in c.result.files {
		nodes := len(c.program.trees[typed.file].nodes)
		testing.expectf(
			t,
			len(typed.node_types) == nodes && len(typed.node_symbols) == nodes,
			"file %d: tables are %d and %d long, want %d",
			typed.file,
			len(typed.node_types),
			len(typed.node_symbols),
			nodes,
			loc = loc,
		)
		for type in typed.node_types {
			testing.expectf(
				t,
				int(type) < len(c.result.types),
				"a node holds type %d, past the end of the table",
				type,
				loc = loc,
			)
		}
		for ref in typed.node_symbols {
			known :=
				int(ref.file) < len(c.program.files) &&
				int(ref.symbol) < len(c.program.bound[ref.file].symbols)
			testing.expectf(t, known, "a node names %v, which is not a symbol", ref, loc = loc)
		}
	}

	for type in c.result.types {
		union_type, is_union := type.(check.Union)
		if !is_union {
			continue
		}
		testing.expectf(
			t,
			len(union_type.members) >= 2,
			"a union of %d members: one member is that member",
			len(union_type.members),
			loc = loc,
		)
		for member, i in union_type.members {
			testing.expectf(
				t,
				int(member) < len(c.result.types),
				"a union member is past the end of the table",
				loc = loc,
			)
			_, nested := c.result.types[member].(check.Union)
			testing.expectf(t, !nested, "a union holds a union", loc = loc)
			if i > 0 {
				testing.expectf(
					t,
					union_type.members[i - 1] != member,
					"a union holds one member twice",
					loc = loc,
				)
			}
		}
	}
}

@(private = "file")
errors_of :: proc(files: []source.File, diagnostics: []diag.Diagnostic) -> []Error {
	errors := make([]Error, len(diagnostics), context.temp_allocator)
	for d, i in diagnostics {
		position := source.position(files[d.span.file], d.span.start)
		errors[i] = {d.code, position.line, position.column}
	}
	return errors
}

// lines joins the parts of a multi-line program, so that a test reads the way the source does.
lines :: proc(parts: ..string) -> string {
	return strings.join(parts, "\n", context.temp_allocator)
}
