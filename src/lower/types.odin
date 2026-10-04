#+private
package lower

import "core:strings"

import "../abi"
import "../check"
import "../ir"

/*
The one place a TypeScript type becomes an IR type. check owns the first world and ir the second,
and requirements 3.1 to 3.6 fix the map between them: a number is an f64, a boolean a machine
boolean, a string a reference to a cell, an object or an array a reference to a cell of its layout,
objects and arrays of several types a reference whose cell header names the layout (Any_Ref), and
anything else that can hold more than one shape at run time is the two-word tagged value.

Two procedures, because deciding and building are two jobs. representation answers the kind alone
and interns nothing, so the decisions ask it: the net under poison, the text of a refusal, typeof.
ir_type interns the layout of an object or an array, and is asked only where a value is built.

A type with no representation answers `false`, and the caller reports Not_Lowered rather than
guessing: a function with a rest parameter, and the generic signatures only the lib declares.

Objects. A layout is keyed by its shallow shape: the field names in canonical order, each with its
slot kind and whether it is optional. Shallow means a string, an object and an array are a
reference slot whatever they point at, so `interface Node { next: Node | null }` has a complete key
before Node is known, and a walk into it would never end. A reference with one of null and undefined
is a pointer where 0 stands for it (Ref_Or_Null, Ref_Or_Undefined), and so is an optional field of a
reference type, since a missing one reads as undefined; any other optional field is Tagged. Objects
and arrays of several types are a slot of their own (Any_Ref and its two kinds that may hold null),
so the key tells `{p: Circle}` from `{p: Circle | Rect}`. The key of a class also says whether a
reference slot holds a string, a function or an object (object_key), which the layout does not.

Which types share a layout or a signature, and which are views, classes.odin decides.
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
	case check.Function:
		if v.variadic {
			return .Void, false
		}
		for param in v.params {
			representation(types, param.type) or_return
		}
		representation(types, v.result) or_return
		return .Closure, true
	case check.Union:
		// So that the objects and the arrays behind the pointer are looked into, as ir_type does.
		if pointer, _, _, held := reference_union(types, v);
		   held && pointer != .Str && pointer != .Closure {
			for member in v.members {
				if member != check.NULL && member != check.UNDEFINED {
					representation(types, member) or_return
				}
			}
		}
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
	ensure(low.arrays.joined, "a type is mapped before its widening class is complete")
	memo := &memo_of(low, types).types[id]
	if !memo.known {
		memo.type, memo.ok = map_type(low, types, id)
		memo.known = true
	}
	return memo.type, memo.ok
}

// binding_type is the IR type of a variable of this type. One of type void holds undefined, as a
// call typed void evaluates to it; only a variable of type never holds nothing.
binding_type :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	type: ir.Type,
	ok: bool,
) {
	if id == check.VOID {
		return ir.TAGGED, true
	}
	return ir_type(low, types, id)
}

map_type :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	type: ir.Type,
	ok: bool,
) {
	representation(types, id) or_return
	#partial switch v in types[id] {
	case check.Object:
		if _, is_view := object_view(low, types, v); is_view {
			return ir.ANY_REF, true
		}
		return ir.ref(object_layout(low, types, v)), true
	case check.Array:
		if _, is_view := array_view(low, types, v); is_view {
			return ir.ANY_REF, true
		}
		return ir.ref(ir.array_layout(&low.builder, array_slot(low, types, v))), true
	case check.Union:
		if member, nullish, held := nullable_member(types, v); held {
			present := ir_type(low, types, member) or_return
			return ir.nullable(present, nullish), true
		}
	}
	return shallow_type(types, id)
}

// made_type is the type of a cell made as this object or array type: the layout of its own class,
// where the type is a view too, whose places also hold the layouts that flow in.
made_type :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	type: ir.Type,
	ok: bool,
) {
	type = ir_type(low, types, id) or_return
	#partial switch v in types[id] {
	case check.Object:
		return ir.ref(object_layout(low, types, v)), true
	case check.Array:
		return ir.ref(ir.array_layout(&low.builder, array_slot(low, types, v))), true
	}
	return type, true
}

// object_view answers the layouts a place of an object type holds where it holds more than one.
object_view :: proc(
	low: ^Lowering,
	types: []check.Type,
	object: check.Object,
) -> (
	[]Object_View,
	bool,
) {
	slots, _ := object_slots(types, object)
	views, found := low.object_views[object_key(types, object, slots)]
	return views, found
}

array_view :: proc(
	low: ^Lowering,
	types: []check.Type,
	array: check.Array,
) -> (
	[]Array_View,
	bool,
) {
	views, found := low.array_views[element_key(low, types, array.element)]
	return views, found
}

// view_layouts interns and answers the layouts of an object or array type that is a view.
view_layouts :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	layouts: []ir.Layout_ID,
	is_view: bool,
) {
	#partial switch v in types[id] {
	case check.Object:
		views := object_view(low, types, v) or_return
		layouts = make([]ir.Layout_ID, len(views), context.temp_allocator)
		for view, i in views {
			layouts[i] = ir.object_layout(&low.builder, view.slots)
		}
		return layouts, true
	case check.Array:
		views := array_view(low, types, v) or_return
		layouts = make([]ir.Layout_ID, len(views), context.temp_allocator)
		for view, i in views {
			layouts[i] = ir.array_layout(&low.builder, view.element)
		}
		return layouts, true
	}
	return nil, false
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
		if v.variadic {
			return "rest parameters"
		}
		for param in v.params {
			if _, ok := representation(types, param.type); !ok {
				return construct_text(types, param.type)
			}
		}
		if _, ok := representation(types, v.result); !ok {
			return construct_text(types, v.result)
		}
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
		// the type of `c ? 2 : 3` and is a plain number at run time. So is a reference with one of
		// null and undefined, where 0 stands for it: `Node | null` is one pointer, and so are
		// objects and arrays of several layouts, which the header of the cell tells apart. A string
		// and an object need the tag of requirements 3.4. Unions are canonical and never nested, so
		// this looks one level down and no further.
		if reference, _, _, held := reference_union(types, v); held {
			return reference, true
		}
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
	case check.Function:
		return .Closure, true
	case check.Type_Var, check.Overload:
		return .Void, false
	}
	return .Void, false
}

// reference_union says whether one pointer holds a union: one reference type with exactly one of
// null and undefined (strings, functions, or one object or array type, which member names), or
// objects and arrays of several types with at most one of them, which are an Any_Ref.
reference_union :: proc(
	types: []check.Type,
	union_type: check.Union,
) -> (
	kind: ir.Type_Kind,
	nullish: ir.Nullish,
	member: check.Type_ID,
	ok: bool,
) {
	for one in union_type.members {
		if one == check.NULL || one == check.UNDEFINED {
			if nullish != .None {
				return .Void, .None, check.ERROR, false
			}
			nullish = .Null if one == check.NULL else .Undefined
			continue
		}
		other := shallow_kind(types, one) or_return
		switch {
		case other != .Str && other != .Closure && other != .Ref:
			return .Void, .None, check.ERROR, false
		case kind == .Void:
			kind, member = other, one
		case other == .Ref && (kind == .Ref || kind == .Any_Ref):
			kind, member = .Any_Ref, check.ERROR
		case:
			return .Void, .None, check.ERROR, false
		}
	}
	return kind, nullish, member, kind == .Any_Ref || kind != .Void && nullish != .None
}

// nullable_member is the object or array type of a union that holds one with null or undefined,
// which gives the pointer its layout.
nullable_member :: proc(
	types: []check.Type,
	union_type: check.Union,
) -> (
	member: check.Type_ID,
	nullish: ir.Nullish,
	ok: bool,
) {
	kind: ir.Type_Kind
	kind, nullish, member, ok = reference_union(types, union_type)
	return member, nullish, ok && kind == .Ref
}

// shallow_type is shallow_kind with what 0 stands for in a reference that may hold null, which is
// what a slot needs. It carries no layout.
shallow_type :: proc(types: []check.Type, id: check.Type_ID) -> (type: ir.Type, ok: bool) {
	type.kind = shallow_kind(types, id) or_return
	if v, is_union := types[id].(check.Union); is_union {
		_, type.nullish, _, _ = reference_union(types, v)
	}
	return type, true
}

// optional_type is what a read of an optional field or parameter answers: undefined as well, which
// a reference takes as its null and anything else as a tag.
optional_type :: proc(type: ir.Type) -> ir.Type {
	if ir.is_reference(type) && type.nullish != .Null {
		return ir.nullable(type, .Undefined)
	}
	return ir.TAGGED
}

field_slot :: proc(types: []check.Type, field: check.Field) -> (slot: abi.Slot_Kind, ok: bool) {
	type := shallow_type(types, field.type) or_return
	if field.optional {
		type = optional_type(type)
	}
	return slot_of(type), true
}

element_slot :: proc(
	types: []check.Type,
	element: check.Type_ID,
) -> (
	slot: abi.Slot_Kind,
	ok: bool,
) {
	type := shallow_type(types, element) or_return
	return slot_of(type), true
}

// slot_of gives a slot of `void` the Tagged kind: map over a callback that returns nothing makes an
// array of undefined.
slot_of :: proc(type: ir.Type) -> abi.Slot_Kind {
	switch type.kind {
	case .F64:
		return .Number
	case .Bool:
		return .Boolean
	case .Str, .Closure, .Ref:
		switch type.nullish {
		case .None:
			return .Ref
		case .Null:
			return .Ref_Or_Null
		case .Undefined:
			return .Ref_Or_Undefined
		}
	case .Any_Ref:
		switch type.nullish {
		case .None:
			return .Any_Ref
		case .Null:
			return .Any_Ref_Or_Null
		case .Undefined:
			return .Any_Ref_Or_Undefined
		}
	case .Tagged, .Void:
		return .Tagged
	case .I32, .I64:
		unreachable()
	}
	return .Tagged
}

// object_slots is the shallow shape of an object, in the canonical order of its fields.
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
object_layout :: proc(low: ^Lowering, types: []check.Type, object: check.Object) -> ir.Layout_ID {
	return ir.object_layout(&low.builder, class_slots(low, types, object))
}

class_slots :: proc(low: ^Lowering, types: []check.Type, object: check.Object) -> []ir.Slot {
	slots, _ := object_slots(types, object)
	if joined, found := class_value(&low.objects, object_key(types, object, slots)); found {
		return joined
	}
	return slots
}

// object_key is the key of an object type's class: its slots, and what each reference slot holds, a
// string, a function or an object, which the slot kind does not tell. So `{pos: string}` and
// `{pos: Vec}`, one layout, are two classes, and a flow of the one leaves the other alone.
object_key :: proc(types: []check.Type, object: check.Object, slots: []ir.Slot) -> string {
	b := strings.builder_make(context.temp_allocator)
	for slot, i in slots {
		strings.write_quoted_string(&b, slot.name)
		strings.write_byte(&b, '?' if slot.optional else ':')
		strings.write_int(&b, int(slot.kind))
		if held, _ := slot_reference(slot.kind); held.kind == .Ref {
			kind, _ := shallow_kind(types, object.fields[i].type)
			strings.write_byte(&b, '/')
			strings.write_int(&b, int(kind))
		}
		strings.write_byte(&b, ',')
	}
	return strings.to_string(b)
}

// object_held is what each field of an object type holds as the type declares it, in the order of
// its slots.
object_held :: proc(types: []check.Type, object: check.Object) -> []ir.Type {
	held := make([]ir.Type, len(object.fields), context.temp_allocator)
	for field, i in object.fields {
		type, _ := shallow_type(types, field.type)
		held[i] = optional_type(type) if field.optional else type
	}
	return held
}

// Type_Memo holds what ir_type and signature_of answered for the types of one check result, by
// Type_ID: each would build slots, keys and signatures again on every call.
Type_Memo :: struct {
	of:         []check.Type, // the table the Type_IDs index
	types:      []Memo_Type,
	signatures: []Memo_Signature,
}

Memo_Type :: struct {
	known: bool,
	ok:    bool,
	type:  ir.Type,
}

Memo_Signature :: struct {
	known:     bool,
	ok:        bool,
	signature: Signature,
}

make_memos :: proc(results: []check.Check_Result) -> []Type_Memo {
	memos := make([]Type_Memo, len(results), context.temp_allocator)
	for result, i in results {
		memos[i] = {
			of         = result.types,
			types      = make([]Memo_Type, len(result.types), context.temp_allocator),
			signatures = make([]Memo_Signature, len(result.types), context.temp_allocator),
		}
	}
	return memos
}

// memo_of finds the memo by the table itself: every types slice lower is given is the table of one
// check result, and there is one result per partition.
memo_of :: proc(low: ^Lowering, types: []check.Type) -> ^Type_Memo {
	for &memo in low.memos {
		if raw_data(memo.of) == raw_data(types) {
			return &memo
		}
	}
	panic("a type table that belongs to no check result")
}
