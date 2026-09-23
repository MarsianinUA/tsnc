package console_tests

import "core:strings"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/gc"

// util.inspect([1, 2, 3]), util.inspect([true, false]), util.inspect(['a', 'b']) and
// util.inspect([1, 'x', null, undefined, true, -0])
@(test)
arrays_of_each_element_kind :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	testing.expect_value(t, inspected(&heap, numbers(&heap, 1, 2, 3)), "[ 1, 2, 3 ]")
	testing.expect_value(t, inspected(&heap, booleans(&heap, true, false)), "[ true, false ]")
	testing.expect_value(t, inspected(&heap, strings_array(&heap, "a", "b")), "[ 'a', 'b' ]")
	mixed := values(
		&heap,
		number(1),
		text(&heap, "x"),
		null(),
		abi.Tagged{},
		boolean(true),
		number(NEGATIVE_ZERO),
	)
	testing.expect_value(t, inspected(&heap, mixed), "[ 1, 'x', null, undefined, true, -0 ]")
}

// util.inspect([[1, [2, [3, [4]]]]]), util.inspect({ a: { b: { c: { d: 1 } } } }) and
// util.inspect([[], {}, [[[[]]]]])
@(test)
past_the_depth_an_array_and_an_object_print_their_kind :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	four := values(&heap, number(4))
	three := values(&heap, number(3), four)
	two := values(&heap, number(2), three)
	nested := values(&heap, values(&heap, number(1), two))
	testing.expect_value(t, inspected(&heap, nested), "[ [ 1, [ 2, [Array] ] ] ]")

	d := object(&heap, D, number(1))
	objects := object(&heap, A, object(&heap, B, object(&heap, C, d)))
	testing.expect_value(t, inspected(&heap, objects), "{ a: { b: { c: [Object] } } }")

	deep := values(&heap, values(&heap, values(&heap, values(&heap, values(&heap)))))
	empty := values(&heap, values(&heap), object(&heap, EMPTY), deep)
	testing.expect_value(t, inspected(&heap, empty), "[ [], {}, [ [ [Array] ] ] ]")
}

// util.inspect(Array.from({ length: 30 }, (_, i) => i + 1)) and
// util.inspect(Array.from({ length: 120 }, (_, i) => i * 7))
@(test)
a_long_array_of_numbers_groups_into_right_aligned_columns :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	thirty := make([]f64, 30, context.temp_allocator)
	for &n, i in thirty {
		n = f64(i + 1)
	}
	testing.expect_value(
		t,
		inspected(&heap, numbers(&heap, ..thirty)),
		"[\n" +
		"   1,  2,  3,  4,  5,  6,  7,  8,  9,\n" +
		"  10, 11, 12, 13, 14, 15, 16, 17, 18,\n" +
		"  19, 20, 21, 22, 23, 24, 25, 26, 27,\n" +
		"  28, 29, 30\n" +
		"]",
	)

	many := make([]f64, 120, context.temp_allocator)
	for &n, i in many {
		n = f64(i * 7)
	}
	testing.expect_value(
		t,
		inspected(&heap, numbers(&heap, ..many)),
		"[\n" +
		"    0,   7,  14,  21,  28,  35,  42,  49,  56,  63,  70,  77,\n" +
		"   84,  91,  98, 105, 112, 119, 126, 133, 140, 147, 154, 161,\n" +
		"  168, 175, 182, 189, 196, 203, 210, 217, 224, 231, 238, 245,\n" +
		"  252, 259, 266, 273, 280, 287, 294, 301, 308, 315, 322, 329,\n" +
		"  336, 343, 350, 357, 364, 371, 378, 385, 392, 399, 406, 413,\n" +
		"  420, 427, 434, 441, 448, 455, 462, 469, 476, 483, 490, 497,\n" +
		"  504, 511, 518, 525, 532, 539, 546, 553, 560, 567, 574, 581,\n" +
		"  588, 595, 602, 609, 616, 623, 630, 637, 644, 651, 658, 665,\n" +
		"  672, 679, 686, 693,\n" +
		"  ... 20 more items\n" +
		"]",
	)
}

// util.inspect(['a', 'bb', 'ccc', 'dddd', 'e', 'f', 'g']) and
// util.inspect(['中文', '日本語', 'ab', '한국어', 'x', '字', 'yy']): anything but numbers lines up on
// the left, and a wide character takes two columns.
@(test)
other_entries_group_into_left_aligned_columns :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	seven := strings_array(&heap, "a", "bb", "ccc", "dddd", "e", "f", "g")
	testing.expect_value(
		t,
		inspected(&heap, seven),
		"[\n  'a',   'bb',\n  'ccc', 'dddd',\n  'e',   'f',\n  'g'\n]",
	)

	cjk := strings_array(
		&heap,
		"\xe4\xb8\xad\xe6\x96\x87",
		"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e",
		"ab",
		"\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4",
		"x",
		"\xe5\xad\x97",
		"yy",
	)
	testing.expect_value(
		t,
		inspected(&heap, cjk),
		"[\n" +
		"  '\xe4\xb8\xad\xe6\x96\x87', '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e',\n" +
		"  'ab',   '\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4',\n" +
		"  'x',    '\xe5\xad\x97',\n" +
		"  'yy'\n" +
		"]",
	)
}

// util.inspect(["it's", `it's "x"`, `it's "x" ${y}`, 'plain']) and
// util.inspect(['a\nb\tc\x00\x7f\x9f\\\b\f\r\x0b', '\ud800', 'x\udc00', '😀'])
@(test)
a_string_takes_the_quote_it_need_not_escape :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	quotes := strings_array(&heap, "it's", "it's \"x\"", "it's \"x\" ${y}", "plain")
	testing.expect_value(
		t,
		inspected(&heap, quotes),
		"[ \"it's\", `it's \"x\"`, 'it\\'s \"x\" ${y}', 'plain' ]",
	)

	controls := [?]u16{'a', '\n', 'b', '\t', 'c', 0, 0x7f, 0x9f, '\\', 8, 12, '\r', 11}
	high := [?]u16{0xd800}
	low := [?]u16{'x', 0xdc00}
	pair := [?]u16{0xd83d, 0xde00}
	escapes := values(
		&heap,
		units_text(&heap, controls[:]),
		units_text(&heap, high[:]),
		units_text(&heap, low[:]),
		units_text(&heap, pair[:]),
	)
	testing.expect_value(
		t,
		inspected(&heap, escapes),
		"[ 'a\\nb\\tc\\x00\\x7F\\x9F\\\\\\b\\f\\r\\x0B', '\\ud800', 'x\\udc00', '\xf0\x9f\x98\x80' ]",
	)
}

// util.inspect([long]) and util.inspect(long) for
// long = 'line one of text\nline two of text\nline three of text that is long enough to break'
@(test)
a_long_string_breaks_after_its_line_ends :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	long := text(
		&heap,
		"line one of text\nline two of text\nline three of text that is long enough to break",
	)
	testing.expect_value(
		t,
		inspected(&heap, values(&heap, long)),
		"[\n" +
		"  'line one of text\\n' +\n" +
		"    'line two of text\\n' +\n" +
		"    'line three of text that is long enough to break'\n" +
		"]",
	)
	testing.expect_value(
		t,
		inspected(&heap, long),
		"'line one of text\\n' +\n" +
		"  'line two of text\\n' +\n" +
		"  'line three of text that is long enough to break'",
	)
}

// Past 10000 units a string is cut: util.inspect('a'.repeat(10002)) ends in
// "'... 2 more characters", and more than 100 elements in "... n more items".
@(test)
long_values_are_cut_where_node_cuts_them :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	letters := make([]u16, 10002, context.temp_allocator)
	for &unit in letters {
		unit = 'a'
	}
	cut := inspected(&heap, units_text(&heap, letters))
	testing.expect_value(t, len(cut), 1 + 10000 + 1 + len("... 2 more characters"))
	testing.expect_value(t, cut[len(cut) - 22:], "'... 2 more characters")

	hundred_one := make([]f64, 101, context.temp_allocator)
	many := inspected(&heap, numbers(&heap, ..hundred_one))
	testing.expect_value(t, many[len(many) - 20:], "\n  ... 1 more item\n]")
}

// util.inspect({ b: 1, 2: 'x', 1: 'y', a: 3 }), util.inspect({ 'a-b': 1, $d: 2, ['__proto__']: 3,
// 'ключ': 4 }), util.inspect({ x: 1 }) and util.inspect({ x: 1, y: undefined })
@(test)
an_object_prints_its_fields_in_table_order :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	keys := object(&heap, KEYS, text(&heap, "y"), text(&heap, "x"), number(1), number(3))
	testing.expect_value(t, inspected(&heap, keys), "{ '1': 'y', '2': 'x', b: 1, a: 3 }")

	quoted := object(&heap, QUOTED, number(1), number(2), number(3), number(4))
	testing.expect_value(
		t,
		inspected(&heap, quoted),
		"{ 'a-b': 1, '$d': 2, ['__proto__']: 3, '\xd0\xba\xd0\xbb\xd1\x8e\xd1\x87': 4 }",
	)

	// An optional field that holds undefined was never set; a required one is printed.
	testing.expect_value(t, inspected(&heap, object(&heap, OPTIONAL, number(1), {})), "{ x: 1 }")
	required := object(&heap, REQUIRED, number(1), {})
	testing.expect_value(t, inspected(&heap, required), "{ x: 1, y: undefined }")
}

// a = [1]; a.push(a); util.inspect(a), and o = { self: null, n: 1 }; o.self = o; util.inspect(o)
@(test)
a_cycle_prints_a_reference :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	array := values(&heap, number(1))
	push(&heap, array, array)
	testing.expect_value(t, inspected(&heap, array), "<ref *1> [ 1, [Circular *1] ]")

	self := object(&heap, SELF, {}, number(1))
	set_field(self.payload.ref, TABLES[int(SELF) - len(abi.Builtin_Table)].fields[0], self)
	testing.expect_value(t, inspected(&heap, self), "<ref *1> { self: [Circular *1], n: 1 }")
}

// util.inspect([f, anon]) for function f() {} and anon = [() => {}][0]
@(test)
a_function_prints_its_name :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	functions := values(&heap, function(&heap, "f", 0, true), function(&heap, "", 0, false))
	testing.expect_value(
		t,
		inspected(&heap, functions),
		"[ [Function: f], [Function (anonymous)] ]",
	)
}

// FORCE_COLOR=1 node -e "console.log([1, 'a', null, undefined, true, f, { k: [2] }])" for
// function f() {}, the same for Array.from({ length: 30 }, (_, i) => i + 1), and a cycle
@(test)
colors_wrap_each_value_in_its_style :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	mixed := values(
		&heap,
		number(1),
		text(&heap, "a"),
		null(),
		{},
		boolean(true),
		function(&heap, "f", 0, true),
		object(&heap, K, numbers(&heap, 2)),
	)
	testing.expect_value(
		t,
		inspected(&heap, mixed, colors = true),
		"[ \x1b[33m1\x1b[39m, \x1b[32m'a'\x1b[39m, \x1b[1mnull\x1b[22m, \x1b[90mundefined\x1b[39m, " +
		"\x1b[33mtrue\x1b[39m, \x1b[36m[Function: f]\x1b[39m, { k: [ \x1b[33m2\x1b[39m ] } ]",
	)

	thirty := make([]f64, 30, context.temp_allocator)
	for &n, i in thirty {
		n = f64(i + 1)
	}
	// The columns are as wide as without colors: the codes take no column.
	testing.expect_value(
		t,
		inspected(&heap, numbers(&heap, ..thirty), colors = true),
		yellow_numbers(
			"[\n" +
			"   1,  2,  3,  4,  5,  6,  7,  8,  9,\n" +
			"  10, 11, 12, 13, 14, 15, 16, 17, 18,\n" +
			"  19, 20, 21, 22, 23, 24, 25, 26, 27,\n" +
			"  28, 29, 30\n" +
			"]",
		),
	)

	array := values(&heap, number(1))
	push(&heap, array, array)
	testing.expect_value(
		t,
		inspected(&heap, array, colors = true),
		"\x1b[36m<ref *1>\x1b[39m [ \x1b[33m1\x1b[39m, \x1b[36m[Circular *1]\x1b[39m ]",
	)
}

// For o = { a: 'a'.repeat(30), b: 'b'.repeat(30), c: 1 }: util.inspect([o, [o]])
@(test)
entries_past_the_break_length_take_a_line_each :: proc(t: ^testing.T) {
	heap: gc.Heap
	init_heap(t, &heap)
	defer gc.heap_destroy(&heap)

	o := object(
		&heap,
		ABC,
		text(&heap, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
		text(&heap, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
		number(1),
	)
	testing.expect_value(
		t,
		inspected(&heap, values(&heap, o, values(&heap, o))),
		"[\n" +
		"  {\n" +
		"    a: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',\n" +
		"    b: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',\n" +
		"    c: 1\n" +
		"  },\n" +
		"  [\n" +
		"    {\n" +
		"      a: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',\n" +
		"      b: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',\n" +
		"      c: 1\n" +
		"    }\n" +
		"  ]\n" +
		"]",
	)
}

// yellow_numbers wraps every run of digits in `plain` in the codes of the number style.
yellow_numbers :: proc(plain: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(plain); {
		if plain[i] < '0' || plain[i] > '9' {
			strings.write_byte(&b, plain[i])
			i += 1
			continue
		}
		end := i
		for end < len(plain) && '0' <= plain[end] && plain[end] <= '9' {
			end += 1
		}
		strings.write_string(&b, "\x1b[33m")
		strings.write_string(&b, plain[i:end])
		strings.write_string(&b, "\x1b[39m")
		i = end
	}
	return strings.to_string(b)
}
