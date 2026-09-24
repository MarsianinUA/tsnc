package lower_tests

import "core:slice"
import "core:testing"

import "../../src/abi"
import "../../src/ir"

// Objects: the layout a type gets, the order a literal prints in, and the store a field takes.

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
two_print_orders_are_one_layout_and_two_rows :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		const first = { a: 1, b: 2 };
		const second = { b: 3, a: 4 };
		console.log(first, second);
	`,
	)
	init, _ := func_named(result.output, "init$m1")
	allocs := instructions_of(init, ir.Alloc)
	if !testing.expectf(t, len(allocs) == 2, "%s", result.text) {
		return
	}
	testing.expect_value(t, allocs[1].layout, allocs[0].layout)
	testing.expect_value(t, allocs[0].table, ir.NO_LAYOUT)
	testing.expect(t, allocs[1].table != ir.NO_LAYOUT, "{b, a} prints in its own order")
	testing.expect_value(t, result.output.base[allocs[1].table], allocs[0].layout)
	testing.expect(t, slice.equal(field_names(result, allocs[1].table), []string{"b", "a"}))
}

// Node prints the keys ECMAScript counts as array indices first, ascending, then the rest in the
// order the literal wrote them: node -e 'console.log({ b: 1, "10": 2, a: 3, "2": 4, "01": 5 })'
@(test)
integer_like_keys_print_first_and_ascending :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		"const record = { b: 1, \"10\": 2, a: 3, \"2\": 4, \"01\": 5 };\nconsole.log(record);\n",
	)
	init, _ := func_named(result.output, "init$m1")
	alloc := instructions_of(init, ir.Alloc)[0]
	printed := field_names(result, alloc.table)
	testing.expectf(t, slice.equal(printed, []string{"2", "10", "b", "a", "01"}), "%v", printed)
}

@(test)
an_optional_field_is_a_tagged_slot_the_literal_may_leave_out :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Options { size: number; label?: string; }
		const small: Options = { size: 1 };
		console.log(small);
	`,
	)
	layout := result.output.layouts[result.output.globals[0].type.layout]
	label := layout.fields[0]
	testing.expect_value(t, label.name, "label")
	testing.expect_value(t, label.kind, abi.Slot_Kind.Tagged)
	testing.expect(t, label.optional, "the table does not mark the field optional")

	// The cell is zero filled, which is undefined in a tagged slot, so nothing stores into it.
	init, _ := func_named(result.output, "init$m1")
	for store in instructions_of(init, ir.Field_Store_Ref) {
		testing.expectf(
			t,
			store.field != 0,
			"the literal stored the field it left out:\n%s",
			result.text,
		)
	}
	alloc := instructions_of(init, ir.Alloc)[0]
	testing.expect(t, slice.equal(field_names(result, alloc.table), []string{"size", "label"}))
}

@(test)
an_interface_that_names_itself_lowers :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Node { value: number; next: Node | null; }
		const tail: Node = { value: 2, next: null };
		const head: Node = { value: 1, next: tail };
		console.log(head.value, head);
	`,
	)
	layout := result.output.layouts[result.output.globals[0].type.layout]
	testing.expect_value(t, layout.fields[0].name, "next")
	testing.expect_value(t, layout.fields[0].kind, abi.Slot_Kind.Tagged)
	testing.expect_value(t, layout.fields[1].kind, abi.Slot_Kind.Number)
}

@(test)
a_field_write_takes_the_store_its_slot_needs :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Item { count: number; name: string; note: string | undefined; }
		function touch(item: Item): void {
			item.count = 2;
			item.name = "b";
			item.note = undefined;
			item.count += 1;
		}
		touch({ count: 1, name: "a", note: "n" });
	`,
	)
	body, _ := func_named(result.output, "m1.touch")
	// A number goes into a plain slot; a string and a tagged value are what the collector traces.
	testing.expectf(t, len(instructions_of(body, ir.Field_Store)) == 2, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Field_Store_Ref)) == 2, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Field_Load)) == 1, "%s", result.text)
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

@(test)
a_function_field_holds_a_closure_and_is_called_through_it :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		"interface Shape { area(): number; }\nfunction show(s: Shape): number {\nreturn s.area();\n}\n",
	)
	show, _ := func_named(result.output, "m1.show")
	loads := instructions_of(show, ir.Field_Load)
	if !testing.expectf(t, len(loads) == 1, "%s", result.text) {
		return
	}
	shape := result.output.layouts[show.params[0].layout]
	testing.expect_value(t, shape.fields[0].kind, abi.Slot_Kind.Ref)
	testing.expectf(t, len(instructions_of(show, ir.Call_Closure)) == 1, "%s", result.text)
}

// field_names lists the fields of a layout row in the order the row holds them, which is the order
// the console prints them in.
field_names :: proc(result: Lowered, row: ir.Layout_ID) -> []string {
	fields := result.output.layouts[row].fields
	names := make([]string, len(fields), context.temp_allocator)
	for field, i in fields {
		names[i] = field.name
	}
	return names
}
