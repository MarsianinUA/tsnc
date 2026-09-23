package check_tests

import "core:testing"

import "../../src/bind"
import "../../src/diag"
import "../../src/source"

// Names that come from another module. A test writes several sources; check_sources names them
// m1.ts, m2.ts and so on, and an import names one of those, so the module graph is the real one.

@(test)
an_imported_value_takes_the_type_of_its_declaration :: proc(t: ^testing.T) {
	c := expect_program(
	t,
	[]string {
		lines(
			`import { answer } from "./m2.ts";`, //
			`const doubled = answer * 2;`,
		),
		`export const answer = 42;`,
	},
	)

	testing.expect_value(t, declared_text(c, "doubled"), "number")
	// The use holds the declaration and not the local alias, so lower reads where the name comes
	// from instead of walking the import tables again.
	ref := use_declaration(c, "answer")
	testing.expect_value(t, ref.file, MAIN + 1)
	testing.expect_value(
		t,
		c.program.bound[ref.file].symbols[ref.symbol].kind,
		bind.Symbol_Kind.Const,
	)
}

@(test)
an_imported_function_is_called_with_its_own_signature :: proc(t: ^testing.T) {
	c := expect_program(
		t,
		[]string {
			lines(
				`import { twice } from "./m2.ts";`, //
				`const four = twice(2);`,
			),
			`export function twice(x: number): number { return x * 2; }`,
		},
	)

	testing.expect_value(t, declared_text(c, "four"), "number")
	testing.expect_value(t, call_text(c), "(x: number) => number")
}

@(test)
an_imported_type_is_the_type_of_its_declaration :: proc(t: ^testing.T) {
	// The same interface, named through an import, is the same row of the table: a type is its
	// declaration, so an object built here fits a function declared there.
	c := expect_program(
	t,
	[]string {
		lines(
			`import { Point, origin } from "./m2.ts";`, //
			`const p: Point = { x: 1, y: 2 };`,
			`const o = origin();`,
		),
		lines(
			`export interface Point { x: number; y: number; }`, //
			`export function origin(): Point { return { x: 0, y: 0 }; }`,
		),
	},
	)

	testing.expect_value(t, declared_text(c, "p"), "Point")
	testing.expect_value(t, declared_text(c, "o"), "Point")
}

@(test)
an_import_may_rename_what_it_takes :: proc(t: ^testing.T) {
	c := expect_program(
	t,
	[]string {
		lines(
			`import { answer as best } from "./m2.ts";`, //
			`const doubled = best * 2;`,
		),
		`export const answer = 42;`,
	},
	)

	testing.expect_value(t, declared_text(c, "doubled"), "number")
}

@(test)
both_spellings_of_a_specifier_name_one_module :: proc(t: ^testing.T) {
	// The T2.8 contract: `"./m"` and `"./m.ts"` both name m.ts, because neither spelling alone passes
	// both Node and tsc.
	expect_program(
		t,
		[]string {
			lines(
				`import { answer } from "./m2";`, //
				`console.log(answer);`,
			),
			`export const answer = 42;`,
		},
	)
}

@(test)
a_name_the_other_module_does_not_export_is_reported :: proc(t: ^testing.T) {
	// The message stands on the name in the import list, where the reader has to fix it, and not at
	// each use: ten uses of one bad import are one mistake.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import { missing } from "./m2.ts";`, //
				`console.log(missing);`,
				`console.log(missing);`,
			),
			`export const answer = 42;`,
		},
		[]File_Error{{MAIN, .Unknown_Export, 1, 10}},
	)
	// Declaring the name in the other module is not enough: without `export` the answer is the
	// same.
	expect_program_errors(
		t,
		[]string{`import { hidden } from "./m2.ts";`, `const hidden = 1;`},
		[]File_Error{{MAIN, .Unknown_Export, 1, 10}},
	)
	// An import nothing uses is still checked: the import list is where the claim is made.
	expect_program_errors(
		t,
		[]string{`import { missing } from "./m2.ts";`, `export const answer = 42;`},
		[]File_Error{{MAIN, .Unknown_Export, 1, 10}},
	)
}

@(test)
the_message_about_an_unknown_export_names_the_module :: proc(t: ^testing.T) {
	c := check_sources(
		t,
		[]string{`import { missing } from "./m2.ts";`, `export const answer = 42;`},
		every_source(2),
	)

	testing.expect_value(t, len(c.diagnostics), 1)
	testing.expect_value(
		t,
		rendered(c, 0),
		"m1.ts:1:10: error[T4009]: module `./m2.ts` does not export `missing`\n  hint: write `export` in front of the declaration of `missing` in that module, or check the spelling; a type and a value of one name are exported separately\n",
	)
}

@(test)
a_re_export_carries_a_name_through :: proc(t: ^testing.T) {
	// The multi-file example of the task's done line: m1 imports from m2, which re-exports what m3
	// declares, and the whole program types. Following the chain is what makes it one declaration.
	c := expect_program(
		t,
		[]string {
			lines(
				`import { twice, Point } from "./m2.ts";`, //
				`const four = twice(2);`,
				`const p: Point = { x: 1, y: 2 };`,
			),
			lines(
				`export { twice } from "./m3.ts";`, //
				`export type { Point } from "./m3.ts";`,
			),
			lines(
				`export interface Point { x: number; y: number; }`, //
				`export function twice(x: number): number { return x * 2; }`,
			),
		},
	)

	testing.expect_value(t, declared_text(c, "four"), "number")
	testing.expect_value(t, declared_text(c, "p"), "Point")
	// The use names m3, where the function is written, not m2, which only passed it on.
	testing.expect_value(t, use_declaration(c, "twice").file, MAIN + 2)
}

@(test)
a_re_export_of_a_name_that_is_nowhere_is_reported :: proc(t: ^testing.T) {
	// Both halves of the chain claim the name, so both are reported: each file says something that
	// is not true about the file it names.
	expect_program_errors(
		t,
		[]string {
			`import { missing } from "./m2.ts";`,
			`export { missing } from "./m3.ts";`,
			`export const answer = 42;`,
		},
		[]File_Error{{MAIN, .Unknown_Export, 1, 10}, {MAIN + 1, .Unknown_Export, 1, 10}},
	)
}

@(test)
a_ring_of_re_exports_answers_that_the_name_is_nowhere :: proc(t: ^testing.T) {
	// Two modules that pass a name to each other declare it in neither, so the walk answers that it
	// is not exported rather than going round again. The test is here to prove it ends at all.
	expect_program_errors(
		t,
		[]string {
			`export { round } from "./m2.ts";`, //
			`export { round } from "./m1.ts";`,
		},
		[]File_Error{{MAIN, .Unknown_Export, 1, 10}, {MAIN + 1, .Unknown_Export, 1, 10}},
	)
}

@(test)
a_module_namespace_resolves_the_name_after_the_dot :: proc(t: ^testing.T) {
	c := expect_program(
		t,
		[]string {
			lines(
				`import * as m from "./m2.ts";`, //
				`const four = m.twice(2);`,
				`const doubled = m.answer * 2;`,
				`const p: m.Point = { x: 1, y: 2 };`,
			),
			lines(
				`export interface Point { x: number; y: number; }`, //
				`export const answer = 42;`,
				`export function twice(x: number): number { return x * 2; }`,
			),
		},
	)

	testing.expect_value(t, declared_text(c, "four"), "number")
	testing.expect_value(t, declared_text(c, "doubled"), "number")
	testing.expect_value(t, declared_text(c, "p"), "Point")
	// `m.twice` is a read of the declaration in m2, not a field of anything, so the member holds the
	// symbol the way a name does.
	testing.expect_value(t, member_text(c, "twice"), "(x: number) => number")
}

@(test)
a_module_namespace_is_not_a_value_of_its_own :: proc(t: ^testing.T) {
	// Requirements 7 asks for the form `import * as m`, and the names behind it resolve straight to
	// their declarations. A value standing for the whole module would have to be built in the heap
	// with every function of that module inside it, so tsnc asks for the name instead.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import * as m from "./m2.ts";`, //
				`console.log(m);`,
			),
			`export const answer = 42;`,
		},
		[]File_Error{{MAIN, .Namespace_As_Value, 2, 13}},
	)
	// A type position asks for the name just as a value position does.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import * as m from "./m2.ts";`, //
				`let held: m = 1;`,
			),
			`export const answer = 42;`,
		},
		[]File_Error{{MAIN, .Namespace_As_Value, 2, 11}},
	)
}

@(test)
a_name_a_module_namespace_does_not_have_is_reported :: proc(t: ^testing.T) {
	// Here the name after the dot is the only place it is written, so this is where it is reported.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import * as m from "./m2.ts";`, //
				`console.log(m.missing);`,
			),
			`export const answer = 42;`,
		},
		[]File_Error{{MAIN, .Unknown_Export, 2, 15}},
	)
}

@(test)
an_imported_type_is_not_a_value :: proc(t: ^testing.T) {
	// A name that is only a type cannot stand where a value belongs, whether the other module
	// declares it as a type or the import asked for the type half alone. The import list itself is
	// right either way: which half a use needs is the use's question.
	expect_program(
		t,
		[]string {
			lines(
				`import type { Point } from "./m2.ts";`, //
				`const p: Point = { x: 1, y: 2 };`,
			),
			`export interface Point { x: number; y: number; }`,
		},
	)
	expect_program_errors(
		t,
		[]string {
			lines(
				`import { Point } from "./m2.ts";`, //
				`console.log(Point);`,
			),
			`export interface Point { x: number; y: number; }`,
		},
		[]File_Error{{MAIN, .Type_Used_As_Value, 2, 13}},
	)
	// `import type` is erased, so the module behind it never runs and there is no value to take even
	// where the other module declares one.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import type { answer } from "./m2.ts";`, //
				`console.log(answer);`,
			),
			`export const answer = 42;`,
		},
		[]File_Error{{MAIN, .Type_Used_As_Value, 2, 13}},
	)
	// The rule follows the chain: a name re-exported as a type only is a type wherever it lands.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import { Point } from "./m2.ts";`, //
				`console.log(Point);`,
			),
			`export type { Point } from "./m3.ts";`,
			`export interface Point { x: number; y: number; }`,
		},
		[]File_Error{{MAIN, .Type_Used_As_Value, 2, 13}},
	)
	// The other way round, an imported value in a type position is a name with no type behind it,
	// which is the same answer a value declared in this file gives.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import { answer } from "./m2.ts";`, //
				`let held: answer = 1;`,
			),
			`export const answer = 42;`,
		},
		[]File_Error{{MAIN, .Cannot_Find_Name, 2, 11}},
	)
}

@(test)
an_imported_binding_cannot_be_assigned_to :: proc(t: ^testing.T) {
	// ESM makes an imported binding read-only whichever keyword declared it in the other module, so
	// it answers as a `const` does.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import { count } from "./m2.ts";`, //
				`count = 2;`,
			),
			`export let count = 1;`,
		},
		[]File_Error{{MAIN, .Assign_To_Const, 2, 1}},
	)
}

@(test)
a_binding_reached_through_a_namespace_cannot_be_assigned_to :: proc(t: ^testing.T) {
	// `m.count` names the same binding an imported `count` does, so the two answer alike.
	expect_program_errors(
		t,
		[]string {
			lines(
				`import * as m from "./m2.ts";`, //
				`m.count = 2;`,
				`m.count++;`,
			),
			`export let count = 1;`,
		},
		[]File_Error{{MAIN, .Assign_To_Const, 2, 3}, {MAIN, .Assign_To_Const, 3, 3}},
	)
}

@(test)
a_cycle_of_types_and_functions_is_allowed :: proc(t: ^testing.T) {
	// Requirements 7 allows a ring as long as no module in it runs anything as it loads. program
	// draws the ring and stays quiet, and check has to resolve both ways round without looping.
	c := expect_program(
		t,
		[]string {
			lines(
				`import { Tag, tag } from "./m2.ts";`, //
				`export interface Node { tag: Tag; }`,
				`export function make(): Node { return { tag: tag() }; }`,
			),
			lines(
				`import { Node } from "./m1.ts";`, //
				`export type Tag = "a" | "b";`,
				`export function tag(): Tag { return "a"; }`,
				`export function tagOf(n: Node): Tag { return n.tag; }`,
			),
		},
	)

	testing.expect_value(t, declared_type_text(c, "Node"), "Node")
	testing.expect_value(t, declared_text(c, "tagOf", MAIN + 1), `(n: Node) => "a" | "b"`)
}

@(test)
a_result_inferred_through_a_ring_of_imports_is_reported_once :: proc(t: ^testing.T) {
	// Two functions in two modules whose results each need the other's: nothing can be inferred, and
	// the answer is the message that asks for an annotation rather than a search that never ends.
	c := check_sources(
		t,
		[]string {
			lines(
				`import { there } from "./m2.ts";`, //
				`export function here() { return there(); }`,
			),
			lines(
				`import { here } from "./m1.ts";`, //
				`export function there() { return here(); }`,
			),
		},
		every_source(2),
	)

	testing.expect_value(t, len(c.file_errors), 1)
	testing.expect_value(t, c.file_errors[0].code, diag.Code.Recursive_Return_Type)
}

@(test)
a_missing_module_says_nothing_here :: proc(t: ^testing.T) {
	// driver reports a specifier that names no file, at the specifier, and program draws no edge for
	// it. check has nothing to add: a second message about the same line would only be noise.
	expect_program(t, []string{`import { answer } from "./nowhere.ts";`})
}

@(test)
one_partition_and_any_split_give_the_same_answer :: proc(t: ^testing.T) {
	// The invariant of Check_Result that T6.2 compares byte for byte. The function in m2 has a result
	// inferred from a narrowed value, which needs the fact tables of that file: a checker that only
	// reads m2 has to reach the same answer as the one that types it.
	sources := [2]string {
		lines(
			`import { widen } from "./m2.ts";`, //
			`const text = widen("a");`,
		),
		lines(
			`export function widen(v: string | number) {`, //
			`	if (typeof v === "string") {`,
			`		return v;`,
			`	}`,
			`	return "n";`,
			`}`,
		),
	}
	whole := [2]source.File_ID{MAIN, MAIN + 1}
	first := [1]source.File_ID{MAIN}
	second := [1]source.File_ID{MAIN + 1}

	together := check_sources(t, sources[:], whole[:])
	apart := check_sources(t, sources[:], first[:])
	owner := check_sources(t, sources[:], second[:])

	testing.expectf(t, len(together.file_errors) == 0, "%v", together.file_errors)
	testing.expectf(t, len(apart.file_errors) == 0, "%v", apart.file_errors)
	testing.expectf(t, len(owner.file_errors) == 0, "%v", owner.file_errors)

	testing.expect_value(t, declared_text(together, "text"), "string")
	testing.expect_value(t, declared_text(apart, "text"), "string")
	// The checker that owns m2 works the same result out from the file itself. The union prints in
	// canonical order, which is structural and the same in every checker.
	testing.expect_value(
		t,
		declared_text(owner, "widen", MAIN + 1),
		"(v: number | string) => string",
	)
	testing.expect_value(
		t,
		declared_text(together, "widen", MAIN + 1),
		"(v: number | string) => string",
	)
}
