package bind_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/ast"
import "../../src/bind"

// LIB_TEXT is the lib file, module zero of every program.
LIB_TEXT :: #load("../../src/lib/lib.d.ts", string)

@(test)
every_import_form_names_the_module_it_comes_from :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			`import { a, b as c, type D } from "./m";`, //
			`import type { E } from "./e";`,
			`import * as ns from "./ns";`,
			`import "./side";`,
		),
	)
	expect_imports(
		t,
		b,
		{
			`a = a from "./m"`,
			`c = b from "./m"`,
			`D = D from "./m" (type)`,
			`E = E from "./e" (type)`,
			`ns = * from "./ns"`,
		},
	)
	testing.expect(t, symbol_of(b, "ns").kind == .Namespace_Import)
	testing.expect(t, bind.is_alias(symbol_of(b, "a").kind))

	// check follows an alias through the record of the symbol it resolved to.
	record, found := bind.import_of(b.bound, symbol_named(b, "c"))
	testing.expect(t, found && record.name.text == "b" && !record.type_only)
	_, not_an_alias := bind.import_of(b.bound, bind.NO_SYMBOL)
	testing.expect(t, !not_an_alias)
}

@(test)
every_export_form_fills_the_export_table :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"export const one = 1, two = 2;", //
			"export function f() {}",
			"export interface P { x: number }",
			"export type Q = number;",
			"const local = 3;",
			"export { local as third, type Q as R };",
		),
	)
	expect_exports(
		t,
		b,
		{"one = one", "two = two", "f = f", "P = P", "Q = Q", "third = local", "R = Q (type)"},
	)

	value, found := bind.lookup_export(b.bound, "third", .Value)
	testing.expect(t, found && value.symbol == symbol_named(b, "local"))
	_, wrong_meaning := bind.lookup_export(b.bound, "third", .Type)
	testing.expect(t, !wrong_meaning)
}

@(test)
a_name_that_is_both_a_type_and_a_value_is_exported_twice :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"interface Shape { size: number }", //
			"declare const Shape: Shape;",
			"export { Shape };",
		),
	)
	expect_exports(t, b, {"Shape = Shape", "Shape = Shape"})

	value, has_value := bind.lookup_export(b.bound, "Shape", .Value)
	type, has_type := bind.lookup_export(b.bound, "Shape", .Type)
	testing.expect(t, has_value && has_type && value.symbol != type.symbol)
}

@(test)
a_reexport_stands_for_a_name_of_another_module :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			`export { x as y } from "./m";`, //
			`export type { T } from "./t";`,
		),
	)
	expect_imports(t, b, {`y = x from "./m"`, `T = T from "./t" (type)`})
	expect_exports(t, b, {"y = y", "T = T (type)"})

	// The name is not visible in this file: only the export table holds it.
	testing.expect(t, bind.lookup(b.bound, bind.MODULE_SCOPE, "y", .Value) == bind.NO_SYMBOL)
}

@(test)
an_export_that_names_nothing_or_repeats_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, "export { nope };", {{.Undeclared_Export, 1, 10}})
	expect_errors(t, "export { console };", {{.Undeclared_Export, 1, 10}})
	expect_errors(
		t,
		lines(
			"const a = 1, b = 2;", //
			"export { a, b as a };",
		),
		{{.Duplicate_Export, 2, 18}},
	)
	expect_errors(
		t,
		lines(
			"export const a = 1;", //
			`export { b as a } from "./m";`,
		),
		{{.Duplicate_Export, 2, 15}},
	)

	// One name may still be exported once as a value and once as a type.
	expect_bound(
		t,
		lines(
			"export interface Shape { size: number }", //
			"export declare const Shape: Shape;",
		),
	)
}

@(test)
a_redeclared_export_is_reported_once :: proc(t: ^testing.T) {
	// The second `f` is one mistake, a name declared twice, and not a name exported twice as well.
	twice := expect_errors(
		t,
		lines(
			"export function f() {}", //
			"export function f() {}",
		),
		{{.Redeclared_Name, 2, 17}},
	)
	expect_exports(t, twice, {"f = f"})

	// A declaration that lost its name exports nothing: the name stands for the `let`.
	lost := expect_errors(t, "let f = 1; export function f() {}", {{.Redeclared_Name, 1, 28}})
	expect_exports(t, lost, {})
}

@(test)
the_effects_flag_says_whether_the_top_level_runs_code :: proc(t: ^testing.T) {
	expect_effects(t, "export function f() { console.log(1); }", false)
	expect_effects(t, "export interface P { x: number }\nexport type Q = P;", false)
	expect_effects(t, lines(`import { a } from "./m";`, "export type T = number;"), false)
	expect_effects(t, "export const PI = 3.14, NAME = `tsnc`;", false)
	expect_effects(t, "const dirs = [1, 2], point = { x: 1, y: -2 };", false)
	expect_effects(t, "const f = (x: number) => x * 2;", false)
	expect_effects(t, "let pending: number;", false)
	expect_effects(t, "const total = 1 + 2 * 3;", false)

	expect_effects(t, "console.log(1);", true)
	expect_effects(t, "const now = start();", true)
	expect_effects(t, "let x = 1; x = 2;", true)
	expect_effects(t, "if (1) { }", true)
	expect_effects(t, "const first = items[0];", true)
	expect_effects(t, "const value = maybe!;", true)
	expect_effects(t, lines(`import { base } from "./m";`, "const derived = base + 1;"), true)
}

@(test)
the_lib_file_binds_without_a_diagnostic :: proc(t: ^testing.T) {
	b := bind_text(t, LIB_TEXT)
	testing.expectf(t, len(b.parse_errors) == 0, "lib.d.ts: parse %v", b.parse_errors)
	testing.expectf(t, len(b.errors) == 0, "lib.d.ts: bind %v", b.errors)
	testing.expect(t, !b.bound.has_side_effects)
	testing.expect(t, len(b.bound.exports) == 0) // its names are global, not exported

	// check resolves a name no file of its own declares in this scope.
	for name in ([]string{"console", "process", "Math", "Number", "String", "NaN", "Infinity"}) {
		symbol := bind.lookup(b.bound, bind.MODULE_SCOPE, name, .Value)
		testing.expectf(t, symbol != bind.NO_SYMBOL, "lib.d.ts declares no value %s", name)
	}
	for name in ([]string{"Console", "Process", "Math", "Number", "String", "Array"}) {
		symbol := bind.lookup(b.bound, bind.MODULE_SCOPE, name, .Type)
		testing.expectf(t, symbol != bind.NO_SYMBOL, "lib.d.ts declares no type %s", name)
	}
}

@(private = "file")
expect_effects :: proc(t: ^testing.T, text: string, expected: bool, loc := #caller_location) {
	b := bind_text(t, text, loc)
	testing.expectf(
		t,
		b.bound.has_side_effects == expected,
		"%q: effects %v, want %v",
		text,
		b.bound.has_side_effects,
		expected,
		loc = loc,
	)
}

// expect_imports checks the import table, one line per alias: `local = name from "./path"`.
@(private = "file")
expect_imports :: proc(t: ^testing.T, b: Bound, expected: []string, loc := #caller_location) {
	lines := make([dynamic]string, context.temp_allocator)
	for record in b.bound.imports {
		name := record.name.text if record.name.text != "" else "*"
		line := fmt.tprintf(
			`%s = %s from %q`,
			b.bound.symbols[record.symbol].name.text,
			name,
			request_path(b, record.request),
		)
		if record.type_only {
			line = strings.concatenate({line, " (type)"}, context.temp_allocator)
		}
		append(&lines, line)
	}
	testing.expectf(
		t,
		slice.equal(lines[:], expected),
		"imports %v, want %v",
		lines[:],
		expected,
		loc = loc,
	)
}

// expect_exports checks the export table, one line per name: `exported = local`.
@(private = "file")
expect_exports :: proc(t: ^testing.T, b: Bound, expected: []string, loc := #caller_location) {
	lines := make([dynamic]string, context.temp_allocator)
	for entry in b.bound.exports {
		local := "?"
		if entry.symbol != bind.NO_SYMBOL {
			local = b.bound.symbols[entry.symbol].name.text
		}
		line := fmt.tprintf("%s = %s", entry.name.text, local)
		if entry.type_only {
			line = strings.concatenate({line, " (type)"}, context.temp_allocator)
		}
		append(&lines, line)
	}
	testing.expectf(
		t,
		slice.equal(lines[:], expected),
		"exports %v, want %v",
		lines[:],
		expected,
		loc = loc,
	)
}

@(private = "file")
request_path :: proc(b: Bound, request: ast.Node_ID) -> string {
	path := ast.NO_NODE
	#partial switch v in b.tree.nodes[request].variant {
	case ast.Import_Named:
		path = v.path
	case ast.Import_Namespace:
		path = v.path
	case ast.Export_Named:
		path = v.path
	}
	literal, is_literal := b.tree.nodes[path].variant.(ast.String_Literal)
	return literal.value if is_literal else ""
}
