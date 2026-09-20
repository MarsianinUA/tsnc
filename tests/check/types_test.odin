package check_tests

import "core:mem/virtual"
import "core:testing"

import "../../src/ast"
import "../../src/bind"
import "../../src/check"
import "../../src/parse"
import "../../src/program"
import "../../src/source"

@(test)
the_types_with_no_parts_are_the_first_rows_of_the_table :: proc(t: ^testing.T) {
	c := expect_checked(t, `const n = 1;`)

	for kind in check.Basic_Kind {
		row, is_basic := c.result.types[check.Type_ID(kind)].(check.Basic_Kind)
		testing.expectf(t, is_basic && row == kind, "row %d is not %v", int(kind), kind)
	}
	testing.expect_value(t, type_text(c, check.ERROR), "?")
	testing.expect_value(t, type_text(c, check.NUMBER), "number")
	testing.expect_value(t, type_text(c, check.UNDEFINED), "undefined")
}

@(test)
one_structure_gets_one_type_id :: proc(t: ^testing.T) {
	// Two signatures that differ only in the names of their parameters are one type in TypeScript,
	// so they have to be one row of the table as well.
	c := expect_checked(
		t,
		lines(
			`const first = (a: number): string => "x";`, //
			`const second = (b: number): string => "y";`,
		),
	)

	typed, ok := check.typed_file(c.result, MAIN)
	testing.expect(t, ok)
	testing.expect_value(t, declared_text(c, "first"), declared_text(c, "second"))
	testing.expect_value(t, type_id_of(c, typed, "first"), type_id_of(c, typed, "second"))
}

@(test)
a_union_is_flattened_deduplicated_and_reduced :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const repeated: string | string = "a";`, //
			`const nested: (string | number) | number = 1;`,
			`const covered: number | 1 = 1;`,
			`const booleans: true | false = true;`,
		),
	)

	// One member left is that member, not a union of one.
	testing.expect_value(t, declared_text(c, "repeated"), "string")
	testing.expect_value(t, declared_text(c, "nested"), "number | string")
	// Every `1` is already a `number`, so naming both says nothing more than `number`.
	testing.expect_value(t, declared_text(c, "covered"), "number")
	// The two of them together are every boolean there is.
	testing.expect_value(t, declared_text(c, "booleans"), "boolean")
}

@(test)
a_union_puts_undefined_last_the_way_typescript_writes_it :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const written: string | undefined = "a";`, //
			`const backwards: undefined | string = "a";`,
		),
	)

	testing.expect_value(t, declared_text(c, "written"), "string | undefined")
	testing.expect_value(t, declared_text(c, "backwards"), "string | undefined")
}

@(test)
two_checkers_spell_one_union_the_same_way :: proc(t: ^testing.T) {
	// The two files write one union with its members the other way round, so each checker meets the
	// two literal types in the opposite order and numbers them the opposite way. An order that
	// leaned on Type_ID would print the two unions differently; a structural one cannot. T6.2
	// compares the whole output of `-j:1` and `-j:8`, and this is what has to hold for it.
	sources := [2]string {
		`const a: "b" | "a" = "a";`, //
		`const b: "a" | "b" = "a";`,
	}
	first := [1]source.File_ID{MAIN}
	second := [1]source.File_ID{MAIN + 1}

	one := check_sources(t, sources[:], first[:])
	two := check_sources(t, sources[:], second[:])

	testing.expect_value(t, declared_text(one, "a", MAIN), `"a" | "b"`)
	testing.expect_value(t, declared_text(two, "b", MAIN + 1), `"a" | "b"`)
}

@(test)
a_function_type_prints_the_way_typescript_writes_it :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const plain: (a: number, b: string) => boolean = (a: number, b: string) => true;`,
			`const optional: (a: number, b?: string) => void = (a: number, b?: string) => {};`,
		),
	)

	testing.expect_value(t, declared_text(c, "plain"), "(a: number, b: string) => boolean")
	testing.expect_value(t, declared_text(c, "optional"), "(a: number, b?: string) => void")
}

@(test)
a_negative_zero_literal_type_is_the_zero_one :: proc(t: ^testing.T) {
	// parse folds the minus of `-0` into the value, while TypeScript has one literal type for both
	// and `-0 === 0` at run time.
	c := expect_checked(t, `const zero: 0 = -0;`)
	testing.expect_value(t, declared_text(c, "zero"), "0")
}

@(test)
the_result_outlives_the_scratch_of_the_check :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	texts := [2]string {
		LIB_TEXT, //
		`const pair = (a: number, b: string) => a > 0 ? b : "none";`,
	}
	files := make([]source.File, len(texts), allocator)
	trees := make([]ast.File_AST, len(texts), allocator)
	bound := make([]bind.Bound_File, len(texts), allocator)
	imports := make([][]program.Import_Edge, len(texts), allocator)
	for text, i in texts {
		files[i] = source.make_file("m.ts", text, allocator)
		trees[i], _ = parse.parse_file(text, source.File_ID(i), allocator)
		bound[i], _ = bind.bind_file(&trees[i], allocator)
	}

	prog, _ := program.build(files, trees, bound, imports, allocator)
	partition := [1]source.File_ID{MAIN}
	result, _ := check.check(&prog, partition[:], allocator)

	free_all(context.temp_allocator) // the scratch of the check is gone

	typed, ok := check.typed_file(result, MAIN)
	testing.expect(t, ok)

	found := false
	for symbol in prog.bound[MAIN].symbols[1:] {
		if symbol.name.text != "pair" {
			continue
		}
		found = true
		text := check.type_text(result.types, typed.node_types[symbol.declaration], allocator)
		testing.expect_value(t, text, "(a: number, b: string) => string")
	}
	testing.expect(t, found)
}

// type_id_of is the raw Type_ID of a declaration, for the one test that has to see that two
// structures share a row rather than only print the same.
@(private = "file")
type_id_of :: proc(c: Checked, typed: ^check.Typed_File, name: string) -> check.Type_ID {
	for symbol in c.program.bound[MAIN].symbols[1:] {
		if symbol.name.text == name && symbol.declaration != ast.NO_NODE {
			return typed.node_types[symbol.declaration]
		}
	}
	return check.ERROR
}
