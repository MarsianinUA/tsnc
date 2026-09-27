package lower_tests

import "core:testing"

import "../../src/ir"

// Objects: the layout a type gets, and the order a place and its value are evaluated in.

@(test)
two_interfaces_of_one_shape_share_a_layout :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Point { x: number; y: number; }
		interface Vec2 { x: number; y: number; }
		const p: Point = { x: 1, y: 2 };
		const v: Vec2 = { x: 3, y: 4 };
		console.log(p, v);
	`,
	)
	p, v := result.output.globals[0], result.output.globals[1]
	testing.expect_value(t, p.type.kind, ir.Type_Kind.Ref)
	testing.expect_value(t, p.type, v.type)
}

@(test)
the_place_is_evaluated_before_the_value :: proc(t: ^testing.T) {
	// `a[i] = (i = 5)` writes at the i the place saw, which is 0.
	result := lower_text(
		t,
		`
		function write(a: number[]): number {
			let i = 0;
			a[i] = (i = 5);
			return i;
		}
		write([1]);
	`,
	)
	body, _ := func_named(result.output, "m1.write")
	checks := instructions_of(body, ir.Bounds_Check)
	stores := instructions_of(body, ir.Element_Store)
	if !testing.expectf(t, len(checks) == 1 && len(stores) == 1, "%s", result.text) {
		return
	}
	index, _ := number_at(body, checks[0].index)
	value, _ := number_at(body, stores[0].value)
	testing.expect_value(t, index, 0)
	testing.expect_value(t, value, 5)
}
