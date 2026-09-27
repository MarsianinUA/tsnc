package check_tests

import "core:testing"

import "../../src/source"

// Names that come from another module. A test writes several sources; check_sources names them
// m1.ts, m2.ts and so on, and an import names one of those, so the module graph is the real one.

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
a_re_export_carries_a_name_through :: proc(t: ^testing.T) {
	// The multi-file example of the task's done line: m1 imports from m2, which re-exports what m3
	// declares, and the whole program types. Following the chain is what makes it one declaration.
	sources := []string {
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
	}
	c := expect_program(t, sources)

	testing.expect_value(t, declared_text(c, "four"), "number")
	testing.expect_value(t, declared_text(c, "p"), "Point")
	// The use names m3, where the function is written, not m2, which only passed it on.
	testing.expect_value(t, use_declaration(c, "twice").file, MAIN + 2)
}

@(test)
a_cycle_of_types_and_functions_is_allowed :: proc(t: ^testing.T) {
	// Requirements 7 allows a ring as long as no module in it runs anything as it loads. program
	// draws the ring and stays quiet, and check has to resolve both ways round without looping.
	sources := []string {
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
	}
	c := expect_program(t, sources)

	testing.expect_value(t, declared_type_text(c, "Node"), "Node")
	testing.expect_value(t, declared_text(c, "tagOf", MAIN + 1), `(n: Node) => "a" | "b"`)
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
