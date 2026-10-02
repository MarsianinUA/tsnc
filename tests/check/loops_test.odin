package check_tests

import "core:slice"
import "core:testing"

// Loops through declarations, and bodies that wait for check_deferred. Every case is checked as one
// partition in both orders and split into two, which enter the loop at different members: all must
// give the diagnostics the case wants.

@(test)
a_loop_is_reported_once_at_the_function_declared_first :: proc(t: ^testing.T) {
	// Two loops share `a`; four functions call each other in two loops that share figureB. m1 enters
	// each loop at another member than the walk of m2 does.
	sources := [2]string {
		lines(
			`import { c, figureD } from "./m2.ts";`, //
			`console.log(c(1), figureD(1));`,
		),
		lines(
			`export function a(n: number) { return n > 0 ? b(n) + c(n) : 0; }`, //
			`export function b(n: number) { return a(n - 1); }`,
			`export function c(n: number) { return a(n - 2) + 1; }`,
			`export function figureA(n: number) { return figureB(n); }`,
			`export function figureB(n: number) { return n > 0 ? figureC(n) + figureD(n) : 0; }`,
			`export function figureC(n: number) { return figureA(n - 1); }`,
			`export function figureD(n: number) { return figureB(n - 1) + 1; }`,
		),
	}
	expect_any_split(
		t,
		sources[:],
		{{MAIN + 1, .Recursive_Return_Type, 1, 17}, {MAIN + 1, .Recursive_Return_Type, 4, 17}},
	)
}

@(test)
an_alias_loop_is_reported_once_at_the_alias_declared_first :: proc(t: ^testing.T) {
	sources := [2]string {
		lines(
			`import type { B, C } from "./m2.ts";`, //
			`export type A = B | C;`,
		),
		lines(
			`import type { A } from "./m1.ts";`, //
			`export type B = A | number;`,
			`export type C = A | string;`,
			`const c: C = "c";`,
		),
	}
	expect_any_split(t, sources[:], {{MAIN, .Circular_Type, 2, 13}})
}

@(test)
a_body_with_a_written_result_closes_no_loop :: proc(t: ^testing.T) {
	// f is typed without its body, so `a` reads a settled f, and f's body a settled `a`, from
	// whichever end the checker starts.
	sources := [2]string {
		lines(
			`import { f } from "./m2.ts";`, //
			`export function a() { return f(); }`,
		),
		lines(
			`import { a } from "./m1.ts";`, //
			`export function f(): number { return a(); }`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
an_initializer_waits_where_the_type_is_written_and_narrows_nothing :: proc(t: ^testing.T) {
	sources := [2]string {
		lines(
			`import { a } from "./m2.ts";`, //
			`export function b() { return a(); }`,
		),
		lines(
			`export const x: number = a();`, //
			`export function a() { return x; }`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
an_initializer_that_narrows_reads_in_place_and_closes_the_loop :: proc(t: ^testing.T) {
	// A read of x is narrowed by its initializer, which has to be read where x is typed, and the
	// loop through `a` is one whichever end a checker starts from. tsc accepts it.
	sources := [2]string {
		lines(
			`import { a } from "./m2.ts";`, //
			`export function b() { return a(); }`,
		),
		lines(
			`export const x: number | string = a();`, //
			`export function a() { return x; }`,
		),
	}
	expect_any_split(t, sources[:], {{MAIN + 1, .Recursive_Return_Type, 2, 17}})
}

@(test)
a_narrowed_read_of_another_module_finds_its_initializer_read :: proc(t: ^testing.T) {
	// n waits for check_deferred, and the read of v in it is narrowed by v's initializer, which must
	// not wait behind it.
	sources := [2]string {
		lines(
			`export let v: number | string = 1;`, //
			`export const n: number = v;`,
		),
		lines(
			`import { n } from "./m1.ts";`, //
			`export const m: number = n;`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
an_initializer_that_writes_a_variable_reads_in_place :: proc(t: ^testing.T) {
	// z is narrowed by the write in k's initializer, which a later read walks through, from
	// whichever end f is first asked for.
	sources := [2]string {
		lines(
			`import { f } from "./m2.ts";`, //
			`export const r: number = f();`,
		),
		lines(
			`export let u: string | number = "a";`, //
			`export const k: number = (u = 1);`,
			`export const z = u;`,
			`export function f() { return k + z; }`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
a_nested_function_with_a_written_result_closes_no_loop :: proc(t: ^testing.T) {
	sources := [2]string {
		lines(
			`export function outer() {`, //
			`	function inner(): number { return outer(); }`,
			`	return inner();`,
			`}`,
		),
		lines(
			`import { outer } from "./m1.ts";`, //
			`export const k = outer();`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
a_waiting_body_reports_once_in_its_own_file :: proc(t: ^testing.T) {
	sources := [2]string {
		`export function f(): number { return "x"; }`,
		lines(
			`import { f } from "./m1.ts";`, //
			`export const y = f();`,
		),
	}
	expect_any_split(t, sources[:], {{MAIN, .Type_Mismatch, 1, 38}})
}

@(test)
an_interface_between_two_reads_of_an_alias_is_no_loop :: proc(t: ^testing.T) {
	// tsc accepts it: the interface holds A, and A holds the interface.
	sources := [2]string {
		lines(
			`import type { I } from "./m2.ts";`, //
			`export type A = I | number;`,
		),
		lines(
			`import type { A } from "./m1.ts";`, //
			`export interface I { a: A; }`,
			`const i: I = { a: 1 };`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
a_loop_of_generic_aliases_is_reported_once_however_many_instances_it_has :: proc(t: ^testing.T) {
	sources := [2]string {
		lines(
			`export type G<T> = G<T> | T;`, //
			`export const z: G<boolean> = true;`,
		),
		lines(
			`import type { G } from "./m1.ts";`, //
			`let a: G<number> = 1;`,
			`let b: G<string> = "s";`,
		),
	}
	expect_any_split(
		t,
		sources[:],
		{{MAIN, .Circular_Type, 1, 13}, {MAIN, .Generic_Declaration, 1, 15}},
	)
}

@(test)
a_generic_declaration_reports_once_however_many_uses_it_has :: proc(t: ^testing.T) {
	sources := [2]string {
		lines(
			`export type Pair<T> = Missing[];`, //
			`export interface Box<T> { map<U>(f: (x: T) => U): Gone; }`,
		),
		lines(
			`import type { Pair, Box } from "./m1.ts";`, //
			`const p: Pair<number> = [];`,
			`const q: Pair<string> = [];`,
			`let a: Box<number> | undefined;`,
			`let b: Box<string> | undefined;`,
		),
	}
	expect_any_split(
		t,
		sources[:],
		{
			{MAIN, .Generic_Declaration, 1, 18},
			{MAIN, .Cannot_Find_Name, 1, 23},
			{MAIN, .Generic_Declaration, 2, 22},
			{MAIN, .Generic_Declaration, 2, 31},
			{MAIN, .Cannot_Find_Name, 2, 51},
		},
	)
}

// expect_any_split checks the two sources as one partition in both orders, and as two partitions,
// each of which reads the other file only to learn its names.
@(private = "file")
expect_any_split :: proc(
	t: ^testing.T,
	sources: []string,
	want: []File_Error,
	loc := #caller_location,
) {
	forward := check_sources(t, sources, {MAIN, MAIN + 1}, loc = loc)
	backward := check_sources(t, sources, {MAIN + 1, MAIN}, loc = loc)
	second := check_sources(t, sources, {MAIN + 1}, loc = loc)
	first := check_sources(t, sources, {MAIN}, loc = loc)

	split := make([dynamic]File_Error, context.temp_allocator)
	append(&split, ..second.file_errors)
	append(&split, ..first.file_errors)
	slice.sort_by(split[:], proc(a, b: File_Error) -> bool {
		if a.file != b.file {
			return a.file < b.file
		}
		if a.line != b.line {
			return a.line < b.line
		}
		return a.column < b.column
	})
	for got, i in ([3][]File_Error{forward.file_errors, backward.file_errors, split[:]}) {
		testing.expectf(t, slice.equal(got, want), "split %d: %v", i, got, loc = loc)
	}
}
