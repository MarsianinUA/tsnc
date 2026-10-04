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

// A flow into a wider object type that nothing writes through leaves the type that flows in alone,
// and Body, which only shares its field's name, keeps a pointer to its Vec and reads it unchecked.
@(test)
an_object_type_only_read_through_keeps_what_flows_in :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Vec { x: number; y: number }
		interface Body { pos: Vec }
		interface Label { pos: string }
		function show(l: { pos: string | number }): void { console.log(l.pos); }
		const lab: Label = { pos: "a" };
		show(lab);
		function move(b: Body): number { return b.pos.x + b.pos.y; }
		console.log(move({ pos: { x: 1, y: 2 } }));
	`,
	)
	move := harness.func_named(t, result.output, "m1.move")
	body := result.output.layouts[move.params[0].layout]
	testing.expectf(t, body.fields[0].kind == .Ref, "%v:\n%s", body.fields[0].kind, result.text)
	unchecked :=
		len(instructions_of(move, ir.Layout_Test)) == 0 &&
		len(instructions_of(move, ir.Tag_Test)) == 0
	testing.expectf(t, unchecked, "%s", result.text)
	show := harness.func_named(t, result.output, "m1.show")
	testing.expectf(t, show.params[0] == ir.ANY_REF, "%s", result.text)
}
