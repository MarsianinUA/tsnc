package check_tests

import "core:strings"
import "core:testing"

// The rules of requirements 2.2 and 2.3 that only check can decide: `declare` and type parameters
// belong to the lib file alone, and the prototype chain and `Symbol` belong to nothing at all. parse
// rejects every "never" rule it can see without a type or a file, and tests/parse covers those.

@(test)
declare_outside_the_lib_file_is_rejected :: proc(t: ^testing.T) {
	// The lib file describes what the runtime provides; a user file is compiled from source, so a
	// declaration with no value behind it would link to nothing. lib_test.odin proves the real lib
	// file, which is full of `declare`, still types without a diagnostic.
	expect_errors(t, `declare const answer: number;`, []Error{{.Declare_Outside_Lib, 1, 1}})
	expect_errors(
		t,
		`declare function twice(x: number): number;`,
		[]Error{{.Declare_Outside_Lib, 1, 1}},
	)
	expect_errors(
		t,
		`declare interface Point { x: number; }`,
		[]Error{{.Declare_Outside_Lib, 1, 1}},
	)
	expect_errors(t, `declare type Id = number;`, []Error{{.Declare_Outside_Lib, 1, 1}})
}

@(test)
the_hint_of_declare_says_what_to_write_instead :: proc(t: ^testing.T) {
	c := check_text(t, `declare const answer: number;`)
	testing.expect_value(t, len(c.diagnostics), 1)
	testing.expectf(
		t,
		strings.contains(rendered(c, 0), "hint: give the declaration a value or a body"),
		"%q",
		rendered(c, 0),
	)
}

@(test)
type_parameters_of_ones_own_are_rejected :: proc(t: ^testing.T) {
	// Requirements 2.2 keeps user generics for v2: only the lib file declares a type variable, and
	// resolve_type_params gives one to no other file. Without this rule the `T` inside would quietly
	// mean the error type, which is the one thing a checker must never do silently. The message
	// stands on the first type parameter, which is where the reader has to delete from.
	expect_errors(
		t,
		`function first<T>(items: T[]): T { return items[0]; }`,
		[]Error{{.Generic_Declaration, 1, 16}},
	)
	expect_errors(t, `interface Box<T> { value: T; }`, []Error{{.Generic_Declaration, 1, 15}})
	expect_errors(t, `type Pair<T> = T[];`, []Error{{.Generic_Declaration, 1, 11}})
	// A signature carries its own type parameters, which is how the lib file writes `map<U>`. Both
	// shapes parse into one Function_Type, so both are reported.
	expect_errors(t, `type Apply = <U>(x: number) => U;`, []Error{{.Generic_Declaration, 1, 15}})
	expect_errors(
		t,
		`interface Mapper { apply<U>(x: number): U; }`,
		[]Error{{.Generic_Declaration, 1, 26}},
	)
}

@(test)
the_lib_file_keeps_its_generics :: proc(t: ^testing.T) {
	// The rule is about the file, not about the syntax: `Array<T>` and `map<U>` live in the lib file
	// and every program leans on them.
	c := expect_checked(t, `const doubled = [1, 2].map(x => x * 2);`)

	testing.expect_value(t, declared_text(c, "doubled"), "number[]")
}

@(test)
the_prototype_chain_is_rejected :: proc(t: ^testing.T) {
	// Requirements 2.2 never supports prototypes: an object of tsnc is the fields its type declares
	// and nothing behind them.
	expect_errors(
		t,
		lines(
			`const p = { x: 1 };`, //
			`const chain = p.__proto__;`,
		),
		[]Error{{.Prototype_Access, 2, 17}},
	)
	expect_errors(
		t,
		lines(
			`function f(): void {}`, //
			`const shape = f.prototype;`,
		),
		[]Error{{.Prototype_Access, 2, 17}},
	)
	// A literal and a type member name it just as a read does, and each is one message: the field is
	// left out of the type, so the exact-type rule has nothing more to say about it.
	expect_errors(t, `const p = { __proto__: 1 };`, []Error{{.Prototype_Access, 1, 13}})
	expect_errors(t, `interface Slot { __proto__: number; }`, []Error{{.Prototype_Access, 1, 18}})
}

@(test)
the_prototype_chain_is_rejected_on_a_value_the_rules_gave_up_on :: proc(t: ^testing.T) {
	// `any` takes any field, so the rule has to be asked before the type is, or the one escape route
	// requirements 2.1 names would still be open.
	expect_errors(
		t,
		lines(
			`const loose: any = 1;`, //
			`const chain = loose.__proto__;`,
		),
		[]Error{{.Prototype_Access, 2, 21}},
	)
}

@(test)
symbol_is_rejected_by_name :: proc(t: ^testing.T) {
	// `Symbol` is in the "never" list of requirements 2.2, and no lib declaration answers for it, so
	// without a rule of its own it would read as a name the reader forgot to import.
	expect_errors(t, `const tag = Symbol;`, []Error{{.Symbol_Global, 1, 13}})
	expect_errors(t, `const tag = Symbol.iterator;`, []Error{{.Symbol_Global, 1, 13}})
	expect_errors(t, `let tag: Symbol = 1;`, []Error{{.Symbol_Global, 1, 10}})
	// Every other name nothing declares is still the ordinary message.
	expect_errors(t, `const tag = nowhere;`, []Error{{.Cannot_Find_Name, 1, 13}})
}

@(test)
changing_the_shape_of_an_object_is_already_closed :: proc(t: ^testing.T) {
	// Requirements 2.1 puts "changing an object's shape through `as any`" at level three, never
	// supported. Two rules that are already in place cover it, and this test is what keeps them
	// covering it: a field the type does not declare cannot be written, and `as any` is refused, so
	// there is no way to reach an object whose shape the checker does not know.
	expect_errors(
		t,
		lines(
			`const p = { x: 1 };`, //
			`p.y = 2;`,
		),
		[]Error{{.Field_Not_Found, 2, 3}},
	)
	expect_errors(
		t,
		lines(
			`const p = { x: 1 };`, //
			`const loose = p as any;`,
		),
		[]Error{{.Unsafe_Assertion, 2, 20}},
	)
}
