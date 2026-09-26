package console_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/console"
import "../../../src/runtime/gc"

// util.format('%s|%d|%i|%f|%j|%O|%c|%%|%', 'str', '42', '12.9', '1.5e3', { a: 1 }, [1], 'css')
@(test)
every_specifier_takes_one_argument :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	args := [?]abi.Tagged {
		text(&heap, "%s|%d|%i|%f|%j|%O|%c|%%|%"),
		text(&heap, "str"),
		text(&heap, "42"),
		text(&heap, "12.9"),
		text(&heap, "1.5e3"),
		object(&heap, A, number(1)),
		numbers(&heap, 1),
		text(&heap, "css"),
	}
	expect_line(t, &heap, args[:], "str|42|12|1500|{\"a\":1}|[ 1 ]||%|%")
}

// util.format('%c|%x|%%|%', 'css', 1), util.format('%s %s', 'only'), util.format('%s', 'a', 'b',
// 1), util.format('100%', 1), util.format('%% %s') and util.format(1, '%s', 'x')
@(test)
what_is_no_specifier_stays_as_it_is :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	probe := [?]abi.Tagged{text(&heap, "%c|%x|%%|%"), text(&heap, "css"), number(1)}
	expect_line(t, &heap, probe[:], "|%x|%|% 1")
	fewer := [?]abi.Tagged{text(&heap, "%s %s"), text(&heap, "only")}
	expect_line(t, &heap, fewer[:], "only %s")
	more := [?]abi.Tagged{text(&heap, "%s"), text(&heap, "a"), text(&heap, "b"), number(1)}
	expect_line(t, &heap, more[:], "a b 1")
	percent := [?]abi.Tagged{text(&heap, "100%"), number(1)}
	expect_line(t, &heap, percent[:], "100% 1")
	alone := [?]abi.Tagged{text(&heap, "%% %s")}
	expect_line(t, &heap, alone[:], "%% %s")
	not_first := [?]abi.Tagged{number(1), text(&heap, "%s"), text(&heap, "x")}
	expect_line(t, &heap, not_first[:], "1 %s x")
	expect_line(t, &heap, nil, "")
}

// util.format('%s %s %s %s %s %s', -0, null, undefined, true, [1, [2, [3]]], { a: { b: 1 } })
@(test)
percent_s_is_string_but_inspects_an_object_to_depth_zero :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	args := [?]abi.Tagged {
		text(&heap, "%s %s %s %s %s %s"),
		number(NEGATIVE_ZERO),
		null(),
		{},
		boolean(true),
		values(&heap, number(1), values(&heap, number(2), values(&heap, number(3)))),
		object(&heap, A, object(&heap, B, number(1))),
	}
	expect_line(t, &heap, args[:], "-0 null undefined true [ 1, [Array] ] { a: [Object] }")
}

// util.format('%d %d %d %d %d %d %d %d %d', '0x10', ' 12 ', '12px', [5], {}, true, null, -0, f),
// util.format('%i %i %i %i %i', '0x1f', '12.9', '-0.5', 1e21, [7.5]) and
// util.format('%f %f %f', ' 3.5abc', 'x', [2.25]) for function f() {}
@(test)
the_number_specifiers_convert_as_node_does :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	d := [?]abi.Tagged {
		text(&heap, "%d %d %d %d %d %d %d %d %d"),
		text(&heap, "0x10"),
		text(&heap, " 12 "),
		text(&heap, "12px"),
		numbers(&heap, 5),
		object(&heap, EMPTY),
		boolean(true),
		null(),
		number(NEGATIVE_ZERO),
		function(&heap, "f", 0, true),
	}
	expect_line(t, &heap, d[:], "16 12 NaN 5 NaN 1 0 -0 NaN")
	i := [?]abi.Tagged {
		text(&heap, "%i %i %i %i %i"),
		text(&heap, "0x1f"),
		text(&heap, "12.9"),
		text(&heap, "-0.5"),
		number(1e21),
		numbers(&heap, 7.5),
	}
	expect_line(t, &heap, i[:], "31 12 -0 1 7")
	f := [?]abi.Tagged {
		text(&heap, "%f %f %f"),
		text(&heap, " 3.5abc"),
		text(&heap, "x"),
		numbers(&heap, 2.25),
	}
	expect_line(t, &heap, f[:], "3.5 NaN 2.25")
}

// util.format('%j %j %j %j', { c: [1, undefined, f], d: undefined, e: NaN, f: -0 }, undefined, f,
// 'q"\n') and, for o = { self: null, n: 1 }; o.self = o, util.format('%j', o)
@(test)
percent_j_is_json :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	f := function(&heap, "f", 0, true)
	shape := object(
		&heap,
		JSON,
		values(&heap, number(1), {}, f),
		{},
		number(NAN),
		number(NEGATIVE_ZERO),
	)
	args := [?]abi.Tagged{text(&heap, "%j %j %j %j"), shape, {}, f, text(&heap, "q\"\n")}
	expect_line(
		t,
		&heap,
		args[:],
		"{\"c\":[1,null,null],\"e\":null,\"f\":0} undefined undefined \"q\\\"\\n\"",
	)

	self := object(&heap, SELF, {}, number(1))
	set_field(self.payload.ref, TABLES[int(SELF) - len(abi.Builtin_Table)].fields[0], self)
	circular := [?]abi.Tagged{text(&heap, "%j"), self}
	expect_line(t, &heap, circular[:], "[Circular]")

	// The key of an object that holds nothing there is taken back out, and a nested array is null.
	nested := object(&heap, JSON, values(&heap, values(&heap, {})), {}, number(NAN), number(2))
	inner := [?]abi.Tagged{text(&heap, "%j"), nested}
	expect_line(t, &heap, inner[:], "{\"c\":[[null]],\"e\":null,\"f\":2}")

	// JSON.stringify of a control character, a lone surrogate and a pair.
	units := [?]u16{'"', '\\', 8, 12, '\n', '\r', '\t', 1, 0x1f, 0xdc00, 0xd83d, 0xde00}
	quoted := [?]abi.Tagged{text(&heap, "%j"), units_text(&heap, units[:])}
	expect_line(
		t,
		&heap,
		quoted[:],
		"\"\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f\\udc00\xf0\x9f\x98\x80\"",
	)
}

// Node runs the program's own toString, valueOf or toJSON there; tsnc refuses instead.
@(test)
a_specifier_refuses_what_node_would_run :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	method := function(&heap, "m", 0, true)
	printable := object(&heap, PRINTABLE, method)
	cases := [?]struct {
		format: string,
		arg:    abi.Tagged,
		want:   console.Format_Error,
	} {
		{"%s", method, .Not_Convertible_To_String},
		{"%s", printable, .Not_Convertible_To_String},
		{"%i", printable, .Not_Convertible_To_String},
		{"%f", method, .Not_Convertible_To_String},
		{"%d", printable, .Not_Convertible_To_Number},
		{"%d", object(&heap, VALUE_OF, method), .Not_Convertible_To_Number},
		{"%j", object(&heap, TO_JSON, method), .Not_Convertible_To_Json},
		{"%j", values(&heap, object(&heap, TO_JSON, method)), .Not_Convertible_To_Json},
	}
	for c in cases {
		args := [?]abi.Tagged{text(&heap, c.format), c.arg}
		_, err := render(&heap, args[:])
		testing.expectf(t, err == c.want, "%s: %v, want %v", c.format, err, c.want)
	}

	// A toString, valueOf or toJSON that is no function is not called: %s inspects the object,
	// valueOf is skipped, and toJSON is a property like any other.
	plain := [?]abi.Tagged {
		text(&heap, "%s %d %j"),
		object(&heap, PRINTABLE, number(1)),
		object(&heap, VALUE_OF, number(2)),
		object(&heap, TO_JSON, number(3)),
	}
	expect_line(t, &heap, plain[:], "{ toString: 1 } NaN {\"toJSON\":3}")
}

// FORCE_COLOR=1 node -e "console.log('%s %d %O %o', 1, 2, 3, [4])": only %O, %o and the values
// after the format string take colors.
@(test)
colors_reach_only_what_inspect_prints :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	args := [?]abi.Tagged {
		text(&heap, "%s %d %O %o"),
		number(1),
		number(2),
		number(3),
		numbers(&heap, 4),
	}
	line, err := render(&heap, args[:], colors = true)
	testing.expect_value(t, err, console.Format_Error.None)
	testing.expect_value(
		t,
		line,
		"1 2 \x1b[33m3\x1b[39m [ \x1b[33m4\x1b[39m, [length]: \x1b[33m1\x1b[39m ]",
	)
}

expect_line :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	args: []abi.Tagged,
	want: string,
	loc := #caller_location,
) {
	line, err := render(heap, args)
	testing.expect_value(t, err, console.Format_Error.None, loc = loc)
	testing.expect_value(t, line, want, loc = loc)
}

// In an ES module, for function g(a, b) {}, h = (a) => {} and anon = [function () {}][0]:
// util.format('%o', g), '%o' of h, of anon, of [1, 2], of [], of { f: g, h } and of [[[[[g]]]]]
@(test)
percent_o_shows_the_hidden_properties :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	g := function(&heap, "g", 2, true)
	h := function(&heap, "h", 1, false)
	anon := function(&heap, "", 0, true)
	expect_o(
		t,
		&heap,
		g,
		"<ref *1> [Function: g] {\n" +
		"  [length]: 2,\n" +
		"  [name]: 'g',\n" +
		"  [prototype]: { [constructor]: [Circular *1] }\n" +
		"}",
	)
	expect_o(t, &heap, h, "[Function: h] { [length]: 1, [name]: 'h' }")
	expect_o(
		t,
		&heap,
		anon,
		"<ref *1> [Function (anonymous)] {\n" +
		"  [length]: 0,\n" +
		"  [name]: '',\n" +
		"  [prototype]: { [constructor]: [Circular *1] }\n" +
		"}",
	)
	expect_o(t, &heap, numbers(&heap, 1, 2), "[ 1, 2, [length]: 2 ]")
	expect_o(t, &heap, numbers(&heap), "[ [length]: 0 ]")
	expect_o(
		t,
		&heap,
		object(&heap, A, values(&heap, g, h)),
		"{\n" +
		"  a: [\n" +
		"    <ref *1> [Function: g] {\n" +
		"      [length]: 2,\n" +
		"      [name]: 'g',\n" +
		"      [prototype]: { [constructor]: [Circular *1] }\n" +
		"    },\n" +
		"    [Function: h] { [length]: 1, [name]: 'h' },\n" +
		"    [length]: 2\n" +
		"  ]\n" +
		"}",
	)
	deep := values(&heap, values(&heap, values(&heap, values(&heap, values(&heap, g)))))
	expect_o(
		t,
		&heap,
		deep,
		"[\n" +
		"  [\n" +
		"    [ [ [ [Function], [length]: 1 ], [length]: 1 ], [length]: 1 ],\n" +
		"    [length]: 1\n" +
		"  ],\n" +
		"  [length]: 1\n" +
		"]",
	)
}

expect_o :: proc(
	t: ^testing.T,
	heap: ^gc.Heap,
	v: abi.Tagged,
	want: string,
	loc := #caller_location,
) {
	args := [?]abi.Tagged{text(heap, "%o"), v}
	expect_line(t, heap, args[:], want, loc)
}

// util.format('%o', Array.from({ length: 101 }, (_, i) => i)): Node groups "... 1 more item" with
// the numbers, and [length] takes its place at the end, which past the array is undefined and
// lines the columns up on the left.
@(test)
percent_o_groups_its_length_as_node_does :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	items := make([]f64, 101, context.temp_allocator)
	for &n, i in items {
		n = f64(i)
	}
	expect_o(
		t,
		&heap,
		numbers(&heap, ..items),
		"[\n" +
		"  0,               1,  2,  3,\n" +
		"  4,               5,  6,  7,\n" +
		"  8,               9,  10, 11,\n" +
		"  12,              13, 14, 15,\n" +
		"  16,              17, 18, 19,\n" +
		"  20,              21, 22, 23,\n" +
		"  24,              25, 26, 27,\n" +
		"  28,              29, 30, 31,\n" +
		"  32,              33, 34, 35,\n" +
		"  36,              37, 38, 39,\n" +
		"  40,              41, 42, 43,\n" +
		"  44,              45, 46, 47,\n" +
		"  48,              49, 50, 51,\n" +
		"  52,              53, 54, 55,\n" +
		"  56,              57, 58, 59,\n" +
		"  60,              61, 62, 63,\n" +
		"  64,              65, 66, 67,\n" +
		"  68,              69, 70, 71,\n" +
		"  72,              73, 74, 75,\n" +
		"  76,              77, 78, 79,\n" +
		"  80,              81, 82, 83,\n" +
		"  84,              85, 86, 87,\n" +
		"  88,              89, 90, 91,\n" +
		"  92,              93, 94, 95,\n" +
		"  96,              97, 98, 99,\n" +
		"  ... 1 more item,\n" +
		"  [length]: 101\n" +
		"]",
	)
}

// %j of a list thousands deep, which Node writes out whole where a walk by native recursion runs
// out of stack:
//
//	node -e 'let o = null; for (let i = 3999; i >= 0; i--) o = { self: o, n: i };
//		console.log(require("util").format("%j", o).length)'
//
// prints 70894, the length the loop below spells out.
@(test)
percent_j_of_a_deep_list_needs_no_deep_stack :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	DEPTH :: 4000
	list := abi.Tagged {
		tag = .Null,
	}
	for i := DEPTH - 1; i >= 0; i -= 1 {
		list = object(&heap, SELF, list, number(f64(i)))
	}
	want := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< DEPTH {
		strings.write_string(&want, "{\"self\":")
	}
	strings.write_string(&want, "null")
	for i := DEPTH - 1; i >= 0; i -= 1 {
		fmt.sbprintf(&want, ",\"n\":%d}", i)
	}
	testing.expect_value(t, strings.builder_len(want), 70894)
	args := [?]abi.Tagged{text(&heap, "%j"), list}
	expect_line(t, &heap, args[:], strings.to_string(want))
}
