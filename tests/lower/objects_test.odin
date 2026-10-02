package lower_tests

import "core:testing"

import "../../src/ir"
import "../harness"

// Objects: the layout a type gets.

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
	p := harness.global_named(t, result.output, "m1.p")
	v := harness.global_named(t, result.output, "m1.v")
	testing.expect_value(t, p.type.kind, ir.Type_Kind.Ref)
	testing.expect_value(t, p.type, v.type)
}
