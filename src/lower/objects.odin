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
	for field in object.fields {
		if field.name == name {
			return true
		}
	}
	return false
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

// field_place finds the slot by name: the cell's layout is its widening class, whose fields are
// the object's own. What a read answers is the field's declared type, undefined included for an
// optional one.
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
	declared := ir.TAGGED
	for field in object.fields {
		if field.name != name {
			continue
		}
		if !field.optional {
			declared = ir_type(s.low, s.types, field.type) or_return
		}
		if declared == ir.VOID {
			declared = ir.TAGGED // a field of `void` holds undefined
		}
		for slot, i in s.low.builder.layouts[value_type(s, cell).layout].fields {
			if slot.name == name {
				return Field_Place{cell = cell, field = i32(i), type = declared}, true
			}
		}
	}
	return nil, false
}

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
	return read_widened(s, held, place.type, span)
}

// read_widened unboxes what a widened slot holds as the field's declared type. A write through
// the wider type may have left another kind there, or for an object field an object of another
// layout, which the declared type cannot hold: that fails here rather than reading it wrong.
@(private)
read_widened :: proc(
	s: ^Func_State,
	held: ir.Value_ID,
	declared: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	tag: abi.Tag
	switch declared.kind {
	case .F64:
		tag = .Number
	case .Bool:
		tag = .Boolean
	case .Str:
		tag = .String
	case .Ref:
		tag = .Object
	case .Closure:
		tag = .Function
	case .Void, .Tagged:
		return held
	}
	fits := ir.emit(&s.fb, ir.BOOL, ir.Tag_Test{value = held, tag = tag}, span)
	unboxed := ir.add_block(&s.fb)
	failed := ir.add_block(&s.fb)
	ir.emit(
		&s.fb,
		ir.VOID,
		ir.Branch{condition = fits, then_block = unboxed, else_block = failed},
		span,
	)
	ir.use_block(&s.fb, failed)
	ir.emit(&s.fb, ir.VOID, ir.Fail{site = fail_site(s.low, span, .Field_Holds_Other_Kind)}, span)

	ir.use_block(&s.fb, unboxed)
	value := ir.emit(&s.fb, declared, ir.Unbox{value = held}, span)
	if declared.kind == .Ref {
		layout := ir.Layout_Test {
			cell   = value,
			layout = declared.layout,
		}
		right := ir.emit(&s.fb, ir.BOOL, layout, span)
		checked := ir.add_block(&s.fb)
		ir.emit(
			&s.fb,
			ir.VOID,
			ir.Branch{condition = right, then_block = checked, else_block = failed},
			span,
		)
		ir.use_block(&s.fb, checked)
	}
	return value
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
	if kind == .Ref || kind == .Tagged {
		store := ir.Field_Store_Ref {
			cell  = place.cell,
			field = place.field,
			value = stored,
		}
		ir.emit(&s.fb, ir.VOID, store, span)
	} else {
		store := ir.Field_Store {
			cell  = place.cell,
			field = place.field,
			value = stored,
		}
		ir.emit(&s.fb, ir.VOID, store, span)
	}
	return true
}

@(private)
slot_kind :: proc(s: ^Func_State, place: Field_Place) -> abi.Slot_Kind {
	return s.low.builder.layouts[value_type(s, place.cell).layout].fields[place.field].kind
}
