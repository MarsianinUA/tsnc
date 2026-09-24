package lower

import "core:slice"

import "../abi"
import "../ast"
import "../check"
import "../ir"
import "../source"

/*
Objects: literals, and the fields a place names.

A literal allocates a cell of its type's layout and stores each property as it evaluates it, in
source order, the order JavaScript evaluates them in. The header of the cell names a table row that
lists the fields in the order Node prints them (print_order), so `{a, b}` and `{b, a}` are one layout
and one IR type and still print the way each was written.

A field is read and written at its slot of the layout. A slot the widening classes made Tagged
(types.odin) holds the value boxed. A read through a type narrower than the slot checks the tag, and
for an object the layout, and fails the program where a write through the wider type of the same
object left something else there (requirements 3.8).
*/

@(private)
lower_object_literal :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Object_Literal,
) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	declared := s.typed.node_types[id]
	object, is_object := s.types[declared].(check.Object)
	type, ok := ir_type(s.low, s.types, declared)
	if !is_object || !ok {
		return later(s, span, construct_text(s.types, declared))
	}

	table := ir.object_table(&s.low.builder, type.layout, print_order(s, node, object))
	cell := ir.emit(&s.fb, type, ir.Alloc{layout = type.layout, table = table}, span)
	complete := true
	for property_id in node.properties {
		property := s.tree.nodes[property_id].variant.(ast.Property)
		value := lower_expression(s, property.value)
		if field, has := find_field(object, property.name.text); has {
			at := s.tree.nodes[property_id].span
			if !flow_intact(s, s.typed.node_types[property.value], field.type, at) {
				value = ir.NO_VALUE
			}
		}
		place, found := field_place(s, cell, object, property.name.text)
		stored :=
			found && store_place(s, &place, value, s.tree.nodes[property_id].span) != ir.NO_VALUE
		complete = complete && stored
	}
	return cell if complete else ir.NO_VALUE
}

// print_order is the order Node prints the literal's own properties in: the integer-like keys
// ascending, then the other properties in the order the literal wrote them. An optional field the
// literal left out follows in canonical order; Node prints one only once it was set, in the order
// it was set (requirements 3.9).
@(private)
print_order :: proc(s: ^Func_State, node: ast.Object_Literal, object: check.Object) -> []string {
	order := make([dynamic]string, 0, len(object.fields), context.temp_allocator)
	for field in object.fields {
		if _, is_index := array_index(field.name); is_index {
			append(&order, field.name)
		}
	}
	slice.sort_by(order[:], proc(a, b: string) -> bool {
		x, _ := array_index(a)
		y, _ := array_index(b)
		return x < y
	})

	written := make([dynamic]string, 0, len(node.properties), context.temp_allocator)
	for property_id in node.properties {
		append(&written, s.tree.nodes[property_id].variant.(ast.Property).name.text)
	}
	for field in object.fields {
		append(&written, field.name)
	}
	for name in written {
		_, is_index := array_index(name)
		if !is_index && !slice.contains(order[:], name) && has_field(object, name) {
			append(&order, name)
		}
	}
	return order[:]
}

@(private)
has_field :: proc(object: check.Object, name: string) -> bool {
	_, found := find_field(object, name)
	return found
}

@(private)
find_field :: proc(object: check.Object, name: string) -> (field: check.Field, found: bool) {
	for candidate in object.fields {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// array_index answers the value of a key ECMAScript orders before the others: the decimal of an
// integer below 2^32 - 1 with no leading zero, so "2" and "10" are one and "01" is not.
@(private)
array_index :: proc(key: string) -> (index: u64, ok: bool) {
	if len(key) == 0 || len(key) > 10 || len(key) > 1 && key[0] == '0' {
		return 0, false
	}
	for digit in transmute([]u8)key {
		if digit < '0' || digit > '9' {
			return 0, false
		}
		index = index * 10 + u64(digit - '0')
	}
	return index, index < 4294967295
}

@(private)
field_place :: proc(
	s: ^Func_State,
	cell: ir.Value_ID,
	object: check.Object,
	name: string,
) -> (
	place: Place,
	ok: bool,
) {
	field, type := field_in(s, value_type(s, cell).layout, object, name) or_return
	return Field_Place{cell = cell, field = field, type = type}, true
}

// field_in finds the slot by name: the layout is the object's widening class, whose fields are the
// object's own. type is what a read answers, the field's declared type, undefined included for an
// optional one.
@(private)
field_in :: proc(
	s: ^Func_State,
	layout: ir.Layout_ID,
	object: check.Object,
	name: string,
) -> (
	field: i32,
	type: ir.Type,
	ok: bool,
) {
	declared := ir.TAGGED
	for one in object.fields {
		if one.name != name {
			continue
		}
		if !one.optional {
			declared = ir_type(s.low, s.types, one.type) or_return
		}
		if declared == ir.VOID {
			declared = ir.TAGGED // a field of `void` holds undefined
		}
		for slot, i in s.low.builder.layouts[layout].fields {
			if slot.name == name {
				return i32(i), declared, true
			}
		}
	}
	return 0, {}, false
}

// load_field reads a widened slot through the field's declared type with a check: a write through
// the wider type may have left another kind there, or another layout.
@(private)
load_field :: proc(s: ^Func_State, place: Field_Place, span: source.Span) -> ir.Value_ID {
	load := ir.Field_Load {
		cell  = place.cell,
		field = place.field,
	}
	if slot_kind(s, place) != .Tagged || place.type == ir.TAGGED {
		return ir.emit(&s.fb, place.type, load, span)
	}
	held := ir.emit(&s.fb, ir.TAGGED, load, span)
	return unbox_checked(s, held, place.type, .Field_Holds_Other_Kind, span)
}

// store_field boxes into a widened slot what the declared type holds unboxed.
@(private)
store_field :: proc(
	s: ^Func_State,
	place: Field_Place,
	value: ir.Value_ID,
	span: source.Span,
) -> bool {
	stored := coerce(s, value, place.type, span)
	kind := slot_kind(s, place)
	if kind == .Tagged {
		stored = coerce(s, stored, ir.TAGGED, span)
	}
	if stored == ir.NO_VALUE {
		return false
	}
	store_slot(s, place.cell, place.field, stored, span)
	return true
}

@(private)
slot_kind :: proc(s: ^Func_State, place: Field_Place) -> abi.Slot_Kind {
	return s.low.builder.layouts[value_type(s, place.cell).layout].fields[place.field].kind
}
