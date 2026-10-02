package check_tests

import "core:slice"
import "core:testing"

// Loops through declarations, bodies that wait for check_deferred, and reads narrowed through the
// top level of a module. Every case is checked as one partition in both orders and split into two,
// which enter the loop at different members: all must give the diagnostics the case wants.

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

@(test)
a_read_narrowed_through_another_modules_top_level_sees_its_writes :: proc(t: ^testing.T) {
	// m1 asks for each name before m2 is walked. The writes above are a statement, the initializer
	// of an earlier declaration, and an earlier declarator of the same statement.
	sources := [2]string {
		lines(
			`import { label, name, pace } from "./m2.ts";`, //
			`export const n: string = name;`,
			`export const k: number = label + pace;`,
		),
		lines(
			`export let mode: string | undefined;`, //
			`mode = "fast";`,
			`export const name: string = mode;`,
			`export let speed: number | string = "slow";`,
			`export const fixed: number = (speed = 1);`,
			`export const pace = speed;`,
			`export let size: number | string = "big";`,
			`export const grow: number = (size = 2), label = size;`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
a_let_read_through_another_modules_top_level_sees_a_call_that_never_returns :: proc(
	t: ^testing.T,
) {
	sources := [2]string {
		lines(
			`import { shown } from "./m2.ts";`, //
			`export const seen: string = shown;`,
		),
		lines(
			`let ready: string;`, //
			`if (process.argv.length > 99) {`,
			`	ready = "yes";`,
			`} else {`,
			`	process.exit(1);`,
			`}`,
			`export const shown = ready;`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
a_loop_through_a_top_level_statement_is_one_whichever_end_a_checker_starts_from :: proc(
	t: ^testing.T,
) {
	// name is narrowed through `mode = a()`, whose value needs name. m2's own walk enters at the
	// statement, m1 at a.
	sources := [2]string {
		lines(
			`import { a } from "./m2.ts";`, //
			`console.log(a());`,
		),
		lines(
			`export let mode: string | number = 1;`, //
			`mode = a();`,
			`export const name = mode;`,
			`export function a() { return name; }`,
		),
	}
	expect_any_split(t, sources[:], {{MAIN + 1, .Circular_Initializer, 3, 14}})
}

@(test)
a_statement_below_one_in_a_loop_is_checked_once_the_loop_is_closed :: proc(t: ^testing.T) {
	// m2's walk asks for name inside the `if`; console.log must not read the `if` half done.
	sources := [2]string {
		lines(
			`import { name } from "./m2.ts";`, //
			`console.log(name);`,
		),
		lines(
			`export const later: (() => string | number)[] = [];`, //
			`export let mode: string | number = "x";`,
			`if (later.push(() => name) > 0) {`,
			`	mode = 1;`,
			`} else {`,
			`	process.exit(1);`,
			`}`,
			`console.log(mode.toFixed(1));`,
			`export const name: string | number = mode;`,
		),
	}
	expect_any_split(t, sources[:], {})
}

@(test)
a_statement_stays_in_its_loop_until_the_loop_is_closed :: proc(t: ^testing.T) {
	// console.log(R) has returned by the time D is read, but it is still in R's loop, and D's read
	// narrows through it.
	sources := [2]string {
		lines(
			`import { R } from "./m2.ts";`, //
			`console.log(R);`,
		),
		lines(
			`export let other: string | number = 2;`, //
			`export let mode: string | number = 1;`,
			`console.log(R);`,
			`export const R = [mode, D];`,
			`export const D = other;`,
			`export const z: string = D;`,
		),
	}
	expect_any_split(t, sources[:], {{MAIN + 1, .Circular_Initializer, 4, 14}})
}

@(test)
a_walk_stops_at_a_statement_that_joins_the_loop :: proc(t: ^testing.T) {
	// m1 asks for name, whose walk takes in console.log(name) and so the loop. Walking on into
	// console.log(E) would draw E into it too, where m2's own walk meets E after the loop is closed.
	sources := [2]string {
		lines(
			`import { name } from "./m2.ts";`, //
			`console.log(name);`,
		),
		lines(
			`export let mode: string | number = 1;`, //
			`console.log(name);`,
			`console.log(E);`,
			`export const E = [name];`,
			`export const name = mode;`,
		),
	}
	expect_any_split(
		t,
		sources[:],
		{{MAIN + 1, .Used_Before_Declaration, 3, 13}, {MAIN + 1, .Circular_Initializer, 5, 14}},
	)
}

@(test)
a_read_in_a_loop_through_the_top_level_narrows_nothing :: proc(t: ^testing.T) {
	// The `if` is half done where m2's own walk asks for flag, and whole where m1 asks first. tsc
	// accepts it, since it does not type the arrow to find the call's effect.
	sources := [2]string {
		lines(
			`import { flag } from "./m2.ts";`, //
			`console.log(flag);`,
		),
		lines(
			`export const later: (() => number | boolean)[] = [];`, //
			`export let mode: string | number = "x";`,
			`if (later.push(() => flag) > 0) {`,
			`	mode = 1;`,
			`} else {`,
			`	process.exit(1);`,
			`}`,
			`export const flag: number | boolean = mode;`,
		),
	}
	expect_any_split(t, sources[:], {{MAIN + 1, .Type_Mismatch, 8, 39}})
}

@(test)
a_let_read_in_a_loop_through_the_top_level_counts_as_unassigned :: proc(t: ^testing.T) {
	sources := [2]string {
		lines(
			`import { shown } from "./m2.ts";`, //
			`console.log(shown);`,
		),
		lines(
			`export const later: (() => string)[] = [];`, //
			`let ready: string;`,
			`if (later.push(() => shown) > 0) {`,
			`	ready = "yes";`,
			`} else {`,
			`	process.exit(1);`,
			`}`,
			`export const shown = ready;`,
		),
	}
	expect_any_split(
		t,
		sources[:],
		{{MAIN + 1, .Circular_Initializer, 8, 14}, {MAIN + 1, .Used_Before_Assigned, 8, 22}},
	)
}

@(test)
a_parameter_is_narrowed_inside_its_own_arrow_only :: proc(t: ^testing.T) {
	// Neither the arrow above that names show nor the exits above f say anything about v, nor do
	// they give x a value.
	sources := [2]string {
		lines(
			`import { f, show } from "./m2.ts";`, //
			`show(f(1));`,
		),
		lines(
			`const later: (() => void)[] = [];`, //
			`later.push(() => show(1));`,
			`export const show = (v: string | number) => {`,
			`	console.log(typeof v === "string" ? v.length : v + 1);`,
			`};`,
			`if (process.argv.length > 0) {`,
			`	process.exit(0);`,
			`} else {`,
			`	process.exit(1);`,
			`}`,
			`export const f = (v: string | number) => (typeof v === "string" ? v.length : 0);`,
			`export const h = (): string => { let x: string; return x; };`,
		),
	}
	expect_any_split(t, sources[:], {{MAIN + 1, .Used_Before_Assigned, 12, 56}})
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
