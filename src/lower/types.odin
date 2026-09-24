package lower

import "core:strings"

import "../abi"
import "../check"
import "../ir"

/*
The one place a TypeScript type becomes an IR type. check owns the first world and ir the second,
and requirements 3.1 to 3.6 fix the map between them: a number is an f64, a boolean a machine
boolean, a string a reference to a cell, an object or an array a reference to a cell of its layout,
and anything that can hold more than one shape at run time is the two-word tagged value.

Two procedures, because deciding and building are two jobs. representation answers the kind alone
and interns nothing, so the decisions ask it: the net under poison, the text of a refusal, typeof.
ir_type interns the layout of an object or an array, and is asked only where a value is built.

A type with no representation answers `false`, and the caller reports Not_Lowered rather than
guessing. Function values are the whole of that list until closures arrive in T5.8.

Objects. A layout is keyed by its shallow shape: the field names in canonical order, each with its
slot kind and whether it is optional. Shallow means a string, an object and an array are a Ref slot
whatever they point at, so `interface Node { next: Node | null }` has a complete key before Node is
known, and a walk into it would never end. An optional field is a Tagged slot, since a missing one
reads as undefined.

Widening. A value of type A that check accepted where B was expected is the same object after the
flow, with no copy, as in Node, so A and B need one layout. lower joins the shallow keys of every
such pair (Check_Result.widenings) into classes before any body is built. The class of a key has
one slot per field: the kind every member agrees on, or Tagged where they differ. A read through the
narrower type then checks the tag (objects.odin).
*/

representation :: proc(types: []check.Type, id: check.Type_ID) -> (kind: ir.Type_Kind, ok: bool) {
	#partial switch v in types[id] {
	case check.Object:
		for field in v.fields {
			field_slot(types, field) or_return
		}
		return .Ref, true
	case check.Array:
		element_slot(types, v.element) or_return
		return .Ref, true
	}
	return shallow_kind(types, id)
}

ir_type :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	type: ir.Type,
	ok: bool,
) {
	kind := representation(types, id) or_return
	#partial switch v in types[id] {
	case check.Object:
		return ir.ref(object_layout(low, types, v)), true
	case check.Array:
		element, _ := element_slot(types, v.element)
		return ir.ref(ir.array_layout(&low.builder, element)), true
	}
	return {kind = kind}, true
}

// construct_text feeds the Not_Lowered message. It names the part with no representation, since
// that part is why the whole has none either.
construct_text :: proc(types: []check.Type, id: check.Type_ID) -> string {
	#partial switch v in types[id] {
	case check.Object:
		for field in v.fields {
			if _, ok := shallow_kind(types, field.type); !ok {
				return construct_text(types, field.type)
			}
		}
	case check.Array:
		if _, ok := shallow_kind(types, v.element); !ok {
			return construct_text(types, v.element)
		}
	case check.Function:
		return "function values"
	case check.Union:
		for member in v.members {
			if _, ok := shallow_kind(types, member); !ok {
				return construct_text(types, member)
			}
		}
	}
	return "values of this type"
}

// shallow_kind is representation with an object or an array taken as a reference and not looked
// into, which is what a slot and a union member need.
@(private)
shallow_kind :: proc(types: []check.Type, id: check.Type_ID) -> (kind: ir.Type_Kind, ok: bool) {
	switch v in types[id] {
	case check.Basic_Kind:
		switch v {
		case .Number:
			return .F64, true
		case .Boolean:
			return .Bool, true
		case .String:
			return .Str, true
		case .Null, .Undefined, .Any, .Unknown:
			return .Tagged, true
		case .Void:
			return .Void, true
		case .Never:
			// The result of a call that does not come back, such as process.exit. Nothing reads it.
			return .Void, true
		case .Error:
			return .Void, false
		}
	case check.Literal:
		switch _ in v.value {
		case f64:
			return .F64, true
		case string:
			return .Str, true
		case bool:
			return .Bool, true
		}
	case check.Union:
		// A union whose members all live in one representation is that representation: `2 | 3` is
		// the type of `c ? 2 : 3` and is a plain number at run time. A union with an object or an
		// array among its members never is: `Node | null` needs the tag of requirements 3.4, and so
		// do two objects of two layouts. Unions are canonical and never nested, so this looks one
		// level down and no further.
		kind = shallow_kind(types, v.members[0]) or_return
		for member in v.members[1:] {
			other := shallow_kind(types, member) or_return
			if other != kind || other == .Ref {
				kind = .Tagged
			}
		}
		if kind == .Ref {
			kind = .Tagged
		}
		return kind, true
	case check.Object, check.Array:
		return .Ref, true
	case check.Function, check.Type_Var, check.Overload:
		return .Void, false
	}
	return .Void, false
}

// field_slot makes an optional field Tagged whatever it holds: a field the literal left out reads
// as undefined.
@(private)
field_slot :: proc(types: []check.Type, field: check.Field) -> (slot: abi.Slot_Kind, ok: bool) {
	kind := shallow_kind(types, field.type) or_return
	if field.optional {
		return .Tagged, true
	}
	return slot_of(kind), true
}

@(private)
element_slot :: proc(
	types: []check.Type,
	element: check.Type_ID,
) -> (
	slot: abi.Slot_Kind,
	ok: bool,
) {
	kind := shallow_kind(types, element) or_return
	return slot_of(kind), true
}

// slot_of gives a slot of `void` the Tagged kind: map over a callback that returns nothing makes an
// array of undefined.
@(private)
slot_of :: proc(kind: ir.Type_Kind) -> abi.Slot_Kind {
	switch kind {
	case .F64:
		return .Number
	case .Bool:
		return .Boolean
	case .Str, .Closure, .Ref:
		return .Ref
	case .Tagged, .Void:
		return .Tagged
	}
	return .Tagged
}

// object_slots is the shallow shape of an object, in the canonical order of its fields.
@(private)
object_slots :: proc(types: []check.Type, object: check.Object) -> (slots: []ir.Slot, ok: bool) {
	slots = make([]ir.Slot, len(object.fields), context.temp_allocator)
	for field, i in object.fields {
		kind := field_slot(types, field) or_return
		slots[i] = {
			name     = field.name,
			kind     = kind,
			optional = field.optional,
		}
	}
	return slots, true
}

// object_layout is the layout of the object's widening class, or of its own shape when it takes
// part in no widening.
@(private)
object_layout :: proc(low: ^Lowering, types: []check.Type, object: check.Object) -> ir.Layout_ID {
	slots, _ := object_slots(types, object)
	if node, found := low.classes[slots_key(slots)]; found {
		slots = low.class_slots[class_root(low, node)]
	}
	return ir.object_layout(&low.builder, slots)
}

// Widening classes.

// build_classes joins the shallow keys of every widening of every result, then gives each class
// root the join of its members' slots. The keys are strings, so the Type_IDs of two checkers never
// meet.
@(private)
build_classes :: proc(low: ^Lowering, results: []check.Check_Result) {
	for result in results {
		for widening in result.widenings {
			source, source_ok := class_node(low, result.types, widening.source)
			target, target_ok := class_node(low, result.types, widening.target)
			if source_ok && target_ok {
				low.class_links[class_root(low, source)] = class_root(low, target)
			}
		}
	}
	for node in 0 ..< len(low.class_links) {
		root := class_root(low, node)
		if root != node {
			low.class_slots[root] = join_slots(low.class_slots[root], low.class_slots[node])
		}
	}
}

// class_node answers the node of an object type's key, making one for a key seen first. A type
// with no representation takes part in nothing: it is reported where it is used.
@(private)
class_node :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	node: int,
	ok: bool,
) {
	object := types[id].(check.Object) or_return
	slots := object_slots(types, object) or_return
	key := slots_key(slots)
	if found, known := low.classes[key]; known {
		return found, true
	}
	node = len(low.class_links)
	append(&low.class_links, node)
	append(&low.class_slots, slots)
	low.classes[key] = node
	return node, true
}

// class_root halves the path as it walks, so a long chain of joins stays cheap to climb.
@(private)
class_root :: proc(low: ^Lowering, node: int) -> int {
	node := node
	for low.class_links[node] != node {
		low.class_links[node] = low.class_links[low.class_links[node]]
		node = low.class_links[node]
	}
	return node
}

// join_slots keeps a kind two members agree on and takes Tagged where they differ. Every member of
// a class has the same fields, since check widens only between two types of one field set.
@(private)
join_slots :: proc(a, b: []ir.Slot) -> []ir.Slot {
	joined := make([]ir.Slot, len(a), context.temp_allocator)
	for slot, i in a {
		joined[i] = slot
		if b[i].kind != slot.kind {
			joined[i].kind = .Tagged
		}
	}
	return joined
}

// slots_key quotes each name, so no name can spell the separators.
@(private)
slots_key :: proc(slots: []ir.Slot) -> string {
	b := strings.builder_make(context.temp_allocator)
	for slot in slots {
		strings.write_quoted_string(&b, slot.name)
		strings.write_byte(&b, '?' if slot.optional else ':')
		strings.write_int(&b, int(slot.kind))
		strings.write_byte(&b, ',')
	}
	return strings.to_string(b)
}
