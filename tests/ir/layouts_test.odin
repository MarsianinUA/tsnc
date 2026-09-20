package ir_tests

import "core:testing"

import "../../src/abi"
import "../../src/ir"

// Everything lives in the temp allocator, which the test runner frees before each test, so a test
// frees nothing.

@(test)
an_object_layout_puts_its_slots_after_the_cell_header :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	fields := [?]ir.Slot {
		{name = "x", kind = .Number},
		{name = "tag", kind = .Tagged},
		{name = "next", kind = .Ref},
	}

	id := ir.object_layout(&p, fields[:])
	layout := p.layouts[id]

	testing.expect_value(t, layout.kind, abi.Cell_Kind.Object)
	testing.expect_value(t, len(layout.fields), 3)
	testing.expect_value(t, layout.fields[0].offset, size_of(abi.Cell_Header))
	testing.expect_value(t, layout.fields[1].offset, size_of(abi.Cell_Header) + 8)
	testing.expect_value(t, layout.fields[2].offset, size_of(abi.Cell_Header) + 8 + 16)
	testing.expect_value(t, layout.size, size_of(abi.Cell_Header) + 8 + 16 + 8)
	testing.expect_value(t, layout.fields[1].name, "tag")
	testing.expect_value(t, layout.fields[2].kind, abi.Slot_Kind.Ref)
}

@(test)
an_array_layout_carries_its_element_kind :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)

	numbers := ir.array_layout(&p, .Number)
	tagged := ir.array_layout(&p, .Tagged)

	testing.expect_value(t, p.layouts[numbers].kind, abi.Cell_Kind.Array)
	testing.expect_value(t, p.layouts[numbers].element, abi.Slot_Kind.Number)
	// The elements live in an allocation of their own, so the cell itself is the fixed part.
	testing.expect_value(t, p.layouts[numbers].size, size_of(abi.Array_Cell))
	testing.expect_value(t, len(p.layouts[numbers].fields), 0)
	testing.expect(t, numbers != tagged, "the element kind is part of the shape")
}

@(test)
an_environment_layout_keeps_its_slots_nameless :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	slots := [?]abi.Slot_Kind{.Ref, .Number}

	id := ir.environment_layout(&p, slots[:])
	layout := p.layouts[id]

	testing.expect_value(t, layout.kind, abi.Cell_Kind.Environment)
	testing.expect_value(t, layout.fields[0].name, "")
	testing.expect_value(t, layout.fields[1].offset, size_of(abi.Cell_Header) + 8)
	testing.expect_value(t, layout.size, size_of(abi.Cell_Header) + 16)
}

@(test)
one_shape_interns_to_one_layout :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	point := [?]ir.Slot{{name = "x", kind = .Number}, {name = "y", kind = .Number}}
	vec2 := [?]ir.Slot{{name = "x", kind = .Number}, {name = "y", kind = .Number}}
	swapped := [?]ir.Slot{{name = "y", kind = .Number}, {name = "x", kind = .Number}}
	renamed := [?]ir.Slot{{name = "x", kind = .Number}, {name = "z", kind = .Number}}

	id := ir.object_layout(&p, point[:])

	// Point and Vec2 share a layout: it is a function of the structure, not of the declaration.
	testing.expect_value(t, ir.object_layout(&p, vec2[:]), id)
	// lower hands the fields over in canonical order, so the order it chose is part of the shape.
	testing.expect(t, ir.object_layout(&p, swapped[:]) != id, "the order is part of the shape")
	testing.expect(t, ir.object_layout(&p, renamed[:]) != id, "a name is part of the shape")
	testing.expect_value(t, len(p.layouts), 4) // the reserved row and three shapes
}

@(test)
table_id_numbers_a_layout_after_the_builtin_tables :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	fields := [?]ir.Slot{{name = "x", kind = .Number}}

	first := ir.object_layout(&p, fields[:])

	testing.expect(t, first != ir.NO_LAYOUT, "the reserved row is never handed out")
	testing.expect_value(t, ir.table_id(first), abi.Type_Table_ID(len(abi.Builtin_Table)))
}

@(test)
the_string_pool_reuses_a_literal_and_keeps_every_unit :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)

	hello := ir.intern_string(&p, "hello")
	again := ir.intern_string(&p, "hello")
	// A lone surrogate escape has no rune of its own, and parse keeps its three WTF-8 bytes, so
	// the pool must not run the text through a rune decoder: \uD800 is one unit, not U+FFFD.
	lone := ir.intern_string(&p, "\xed\xa0\x80")
	// U+1F600 is one rune and two UTF-16 units.
	emoji := ir.intern_string(&p, "\xf0\x9f\x98\x80")

	testing.expect_value(t, again, hello)
	testing.expect_value(t, len(p.string_pool), 3)
	testing.expect_value(t, len(p.string_pool[hello]), 5)
	testing.expect_value(t, len(p.string_pool[lone]), 1)
	testing.expect_value(t, p.string_pool[lone][0], u16(0xD800))
	testing.expect_value(t, len(p.string_pool[emoji]), 2)
	testing.expect_value(t, p.string_pool[emoji][0], u16(0xD83D))
	testing.expect_value(t, p.string_pool[emoji][1], u16(0xDE00))
}

@(test)
a_fail_site_is_recorded_once :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	site := abi.Fail_Site {
		file   = "main.ts",
		line   = 3,
		column = 5,
		error  = .Index_Out_Of_Range,
	}
	other := site
	other.error = .Index_Not_Integer

	id := ir.fail_site(&p, site)

	testing.expect_value(t, ir.fail_site(&p, site), id)
	testing.expect(t, ir.fail_site(&p, other) != id, "the error is part of a site")
	testing.expect_value(t, p.fail_sites[id], site)
}
