package console_tests

import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/console"
import "../../../src/runtime/gc"

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
