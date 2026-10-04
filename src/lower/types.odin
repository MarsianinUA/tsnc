package lower

import "core:slice"
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
so the key tells `{p: Circle}` from `{p: Circle | Rect}`.

Widening. A value of type A that check accepted where B was expected is the same object after the
flow, with no copy, as in Node, so A and B need one layout. lower joins the shallow keys of every
such pair (Check_Result.widenings) into classes before any body is built. The class of a key has
one slot per field: the kind every member agrees on, the one that may hold null where the other
holds a present reference, the one of several layouts where the other holds one, or Tagged where
they differ otherwise. A read through the narrower type then checks the tag, the layout, or for
null (objects.odin).

Arrays. An array layout is the kind of its element slot. An array that check accepted where an
array of a wider element was expected is the same array after the flow too, so the two types need
one slot. Their classes are built the way the widening classes are, joining the slot kinds, and
keyed by the element below the slot: the class fields of an object, the element of an inner array.
So a flow of `Triangle[]` into `(Sphere | Triangle)[]` leaves `string[]` alone. A read through the
narrower element checks the slot (arrays.odin).

Functions. A function value is a closure, whatever its signature, and its signature is the IR types
of its parameters and its result. A function accepted where another function type was expected is
the same closure after the flow, so the two types need one signature, or a call through the second
would pass arguments the first does not take. Signature classes are built the way the widening
classes are, over the whole program: a parameter every member agrees on keeps its type, one they
differ on is Tagged, and so is the result, where a member that returns nothing answers undefined.
A class of void functions has a tagged result as well where one of them returns what a call
answered, which Node passes on (widen_void_results, closures.odin). A function then takes the
arguments of its class and unboxes each into its own type (coerce), and a call gives the class what
it wants and unboxes the answer. A declaration with no environment, which a call may name directly,
keeps its own signature instead, so a flow it never meets leaves it alone, and its value runs an
adapter with the signature of its class (closure_func).
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

@(private)
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
		return ir.ref(object_layout(low, types, v)), true
	case check.Array:
		return ir.ref(ir.array_layout(&low.builder, array_slot(low, types, v))), true
	case check.Union:
		if member, nullish, held := nullable_member(types, v); held {
			present := ir_type(low, types, member) or_return
			return ir.nullable(present, nullish), true
		}
	}
	return shallow_type(types, id)
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
@(private)
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
@(private)
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
@(private)
shallow_type :: proc(types: []check.Type, id: check.Type_ID) -> (type: ir.Type, ok: bool) {
	type.kind = shallow_kind(types, id) or_return
	if v, is_union := types[id].(check.Union); is_union {
		_, type.nullish, _, _ = reference_union(types, v)
	}
	return type, true
}

// optional_type is what a read of an optional field or parameter answers: undefined as well, which
// a reference takes as its null and anything else as a tag.
@(private)
optional_type :: proc(type: ir.Type) -> ir.Type {
	if ir.is_reference(type) && type.nullish != .Null {
		return ir.nullable(type, .Undefined)
	}
	return ir.TAGGED
}

@(private)
field_slot :: proc(types: []check.Type, field: check.Field) -> (slot: abi.Slot_Kind, ok: bool) {
	type := shallow_type(types, field.type) or_return
	if field.optional {
		type = optional_type(type)
	}
	return slot_of(type), true
}

@(private)
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
@(private)
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
	return ir.object_layout(&low.builder, class_slots(low, types, object))
}

@(private)
class_slots :: proc(low: ^Lowering, types: []check.Type, object: check.Object) -> []ir.Slot {
	slots, _ := object_slots(types, object)
	if joined, found := class_value(&low.objects, slots_key(slots)); found {
		return joined
	}
	return slots
}

// Classes is a union-find over string keys, each node holding a value. join_classes gives every
// root the join of its class, and class_value answers it for any key of the class. The keys are
// strings, so the Type_IDs of two checkers never meet.
Classes :: struct($V: typeid) {
	nodes:  map[string]int,
	links:  [dynamic]int,
	values: [dynamic]V,
	joined: bool, // join_classes ran, so what class_value answers is final
}

@(private)
make_classes :: proc($V: typeid) -> Classes(V) {
	return {
		nodes = make(map[string]int, context.temp_allocator),
		links = make([dynamic]int, context.temp_allocator),
		values = make([dynamic]V, context.temp_allocator),
	}
}

// class_node answers the node of a key, making one that holds value for a key seen first.
@(private)
class_node :: proc(classes: ^Classes($V), key: string, value: V) -> int {
	if node, known := classes.nodes[key]; known {
		return node
	}
	node := len(classes.links)
	append(&classes.links, node)
	append(&classes.values, value)
	classes.nodes[key] = node
	return node
}

@(private)
class_union :: proc(classes: ^Classes($V), a, b: int) {
	classes.links[class_root(classes, a)] = class_root(classes, b)
}

// class_root halves the path as it walks, so a long chain of joins stays cheap to climb.
@(private)
class_root :: proc(classes: ^Classes($V), node: int) -> int {
	node := node
	for classes.links[node] != node {
		classes.links[node] = classes.links[classes.links[node]]
		node = classes.links[node]
	}
	return node
}

@(private)
join_classes :: proc(classes: ^Classes($V), join: proc(a, b: V) -> V) {
	for node in 0 ..< len(classes.links) {
		root := class_root(classes, node)
		if root != node {
			classes.values[root] = join(classes.values[root], classes.values[node])
		}
	}
	classes.joined = true
}

// class_value answers false for a key that takes part in no class.
@(private)
class_value :: proc(classes: ^Classes($V), key: string) -> (value: V, found: bool) {
	node := classes.nodes[key] or_return
	return classes.values[class_root(classes, node)], true
}

// build_classes joins the shallow keys of every widening of every result, then the arrays, then the
// signatures of every pair of function types a flow recorded. The key of an array names the class
// fields of an object element, and the key of a signature the full IR types, layouts included, so
// each pass comes after the classes it reads are final.
@(private)
build_classes :: proc(low: ^Lowering, results: []check.Check_Result) {
	union_widenings(low, results, &low.objects, object_node)
	join_classes(&low.objects, join_slots)
	union_widenings(low, results, &low.arrays, array_node)
	join_classes(&low.arrays, join_slot_kind)

	intern_signature_layouts(low, results)
	interned := len(low.builder.layouts)
	union_widenings(low, results, &low.signatures, signature_node)
	ensure(
		len(low.builder.layouts) == interned,
		"a signature interned a layout intern_signature_layouts did not see",
	)
	join_classes(&low.signatures, join_signatures)
}

// union_widenings joins the two nodes of every widening that names a type of the classes' kind.
@(private)
union_widenings :: proc(
	low: ^Lowering,
	results: []check.Check_Result,
	classes: ^Classes($V),
	node: proc(low: ^Lowering, types: []check.Type, id: check.Type_ID) -> (int, bool),
) {
	for result in results {
		for widening in result.widenings {
			source, source_ok := node(low, result.types, widening.source)
			target, target_ok := node(low, result.types, widening.target)
			if source_ok && target_ok {
				class_union(classes, source, target)
			}
		}
	}
}

// intern_signature_layouts interns the layouts of the signature pass in key order. That pass meets
// them in the order of the results and their Type_IDs, which differs between -j:1 and -j:8.
@(private)
intern_signature_layouts :: proc(low: ^Lowering, results: []check.Check_Result) {
	wanted := Signature_Layouts {
		objects = make([dynamic]Object_Shape, context.temp_allocator),
	}
	for result in results {
		for widening in result.widenings {
			collect_signature(low, result.types, widening.source, &wanted)
			collect_signature(low, result.types, widening.target, &wanted)
		}
	}

	for element in wanted.arrays {
		ir.array_layout(&low.builder, element)
	}
	slice.sort_by(wanted.objects[:], proc(a, b: Object_Shape) -> bool {
		return a.key < b.key
	})
	for object in wanted.objects {
		ir.object_layout(&low.builder, object.slots)
	}
}

@(private)
Signature_Layouts :: struct {
	arrays:  bit_set[abi.Slot_Kind],
	objects: [dynamic]Object_Shape,
}

@(private)
Object_Shape :: struct {
	key:   string,
	slots: []ir.Slot,
}

// collect_signature and collect_layout mirror own_signature and map_type, early exits included.
@(private)
collect_signature :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
	wanted: ^Signature_Layouts,
) {
	function, is_function := types[id].(check.Function)
	if !is_function || function.variadic {
		return
	}
	for param in function.params {
		if !collect_layout(low, types, param.type, wanted) {
			return
		}
	}
	collect_layout(low, types, function.result, wanted)
}

@(private)
collect_layout :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
	wanted: ^Signature_Layouts,
) -> bool {
	representation(types, id) or_return
	#partial switch v in types[id] {
	case check.Object:
		slots := class_slots(low, types, v)
		append(&wanted.objects, Object_Shape{key = slots_key(slots), slots = slots})
	case check.Array:
		wanted.arrays += {array_slot(low, types, v)}
	case check.Union:
		if member, _, held := nullable_member(types, v); held {
			collect_layout(low, types, member, wanted)
		}
	}
	return true
}

// object_node answers the node of an object type's key. A type with no representation takes part
// in nothing: it is reported where it is used.
@(private)
object_node :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	node: int,
	ok: bool,
) {
	object := types[id].(check.Object) or_return
	slots := object_slots(types, object) or_return
	return class_node(&low.objects, slots_key(slots), slots), true
}

// join_slots joins each field. Every member of a class has the same fields, since check widens only
// between two types of one field set.
@(private)
join_slots :: proc(a, b: []ir.Slot) -> []ir.Slot {
	joined := make([]ir.Slot, len(a), context.temp_allocator)
	for slot, i in a {
		joined[i] = slot
		joined[i].kind = join_slot_kind(slot.kind, b[i].kind)
	}
	return joined
}

// join_slot_kind keeps a kind two members agree on, a reference that may hold null where the other
// member holds a present one, a reference of several layouts where the other holds one, and takes
// Tagged where they differ otherwise.
@(private)
join_slot_kind :: proc(a, b: abi.Slot_Kind) -> abi.Slot_Kind {
	x, x_reference := slot_reference(a)
	y, y_reference := slot_reference(b)
	switch {
	case a == b:
		return a
	case !x_reference || !y_reference:
		return .Tagged
	case x.nullish != .None && y.nullish != .None && x.nullish != y.nullish:
		return .Tagged
	}
	joined := ir.Type {
		kind    = .Any_Ref if x.kind == .Any_Ref || y.kind == .Any_Ref else .Ref,
		nullish = max(x.nullish, y.nullish),
	}
	return slot_of(joined)
}

// slot_reference is the shallow type of a reference slot: Ref or Any_Ref, with its nullish.
@(private)
slot_reference :: proc(kind: abi.Slot_Kind) -> (type: ir.Type, ok: bool) {
	switch kind {
	case .Number, .Boolean, .Tagged:
		return ir.VOID, false
	case .Ref:
		return {kind = .Ref}, true
	case .Ref_Or_Null:
		return {kind = .Ref, nullish = .Null}, true
	case .Ref_Or_Undefined:
		return {kind = .Ref, nullish = .Undefined}, true
	case .Any_Ref:
		return {kind = .Any_Ref}, true
	case .Any_Ref_Or_Null:
		return {kind = .Any_Ref, nullish = .Null}, true
	case .Any_Ref_Or_Undefined:
		return {kind = .Any_Ref, nullish = .Undefined}, true
	}
	return ir.VOID, false
}

// array_slot is the element slot of the array's class, or its own where it takes part in no flow.
@(private)
array_slot :: proc(low: ^Lowering, types: []check.Type, array: check.Array) -> abi.Slot_Kind {
	if joined, found := class_value(&low.arrays, element_key(low, types, array.element)); found {
		return joined
	}
	own, _ := element_slot(types, array.element)
	return own
}

@(private)
array_node :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	node: int,
	ok: bool,
) {
	array := types[id].(check.Array) or_return
	slot := element_slot(types, array.element) or_return
	return class_node(&low.arrays, element_key(low, types, array.element), slot), true
}

@(private)
element_key :: proc(low: ^Lowering, types: []check.Type, element: check.Type_ID) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_element_key(&b, low, types, element)
	return strings.to_string(b)
}

@(private)
write_element_key :: proc(
	b: ^strings.Builder,
	low: ^Lowering,
	types: []check.Type,
	element: check.Type_ID,
) {
	type, _ := shallow_type(types, element)
	write_type_key(b, type)
	below := element
	if v, is_union := types[element].(check.Union); is_union {
		if member, _, held := nullable_member(types, v); held {
			below = member
		}
	}
	#partial switch v in types[below] {
	case check.Object:
		strings.write_byte(b, '{')
		strings.write_string(b, slots_key(class_slots(low, types, v)))
		strings.write_byte(b, '}')
	case check.Array:
		strings.write_byte(b, '[')
		write_element_key(b, low, types, v.element)
		strings.write_byte(b, ']')
	}
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

// Signature is what a call of a function passes and gets back, in IR types.
Signature :: struct {
	params: []ir.Type,
	result: ir.Type,
}

// own_signature is the shape of one function type on its own. A parameter a call may leave out is
// Tagged, since it arrives as undefined then, and so is one of type void. A function with a rest
// parameter has none.
own_signature :: proc(
	low: ^Lowering,
	types: []check.Type,
	function: check.Function,
) -> (
	signature: Signature,
	ok: bool,
) {
	if function.variadic {
		return {}, false
	}
	params := make([]ir.Type, len(function.params), context.temp_allocator)
	for param, i in function.params {
		params[i] = ir_type(low, types, param.type) or_return
		if params[i] == ir.VOID {
			params[i] = ir.TAGGED
		} else if i >= function.required {
			params[i] = optional_type(params[i])
		}
	}
	result := ir_type(low, types, function.result) or_return
	return {params = params, result = result}, true
}

// signature_of answers the signature of a function type's class, or its own for a type that took
// part in no flow.
signature_of :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	signature: Signature,
	ok: bool,
) {
	ensure(low.signatures.joined, "a function type is mapped before its class is complete")
	memo := &memo_of(low, types).signatures[id]
	if !memo.known {
		memo.signature, memo.ok = class_signature(low, types, id)
		memo.known = true
	}
	return memo.signature, memo.ok
}

@(private)
class_signature :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	signature: Signature,
	ok: bool,
) {
	function := types[id].(check.Function) or_return
	signature = own_signature(low, types, function) or_return
	if joined, found := class_value(&low.signatures, signature_key(signature)); found {
		return joined, true
	}
	return signature, true
}

signature_equal :: proc(a, b: Signature) -> bool {
	return a.result == b.result && slice.equal(a.params, b.params)
}

@(private)
signature_node :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	node: int,
	ok: bool,
) {
	function := types[id].(check.Function) or_return
	signature := own_signature(low, types, function) or_return
	return class_node(&low.signatures, signature_key(signature), signature), true
}

// join_signatures gives a parameter only one member has that member's type, and a reference that may
// hold null where the other member takes or gives a present one. A result of void joined with
// another is tagged like any two results that differ otherwise: a call through the class may print
// what it gets back, which is undefined from a member that returns nothing (handed_on).
@(private)
join_signatures :: proc(a, b: Signature) -> Signature {
	join :: proc(x, y: ir.Type) -> ir.Type {
		switch {
		case ir.fits(x, y):
			return y
		case ir.fits(y, x):
			return x
		}
		return ir.TAGGED
	}
	params := make([]ir.Type, max(len(a.params), len(b.params)), context.temp_allocator)
	for &param, i in params {
		switch {
		case i >= len(a.params):
			param = b.params[i]
		case i >= len(b.params):
			param = a.params[i]
		case:
			param = join(a.params[i], b.params[i])
		}
	}
	return {params = params, result = join(a.result, b.result)}
}

@(private)
signature_key :: proc(signature: Signature) -> string {
	b := strings.builder_make(context.temp_allocator)
	for param in signature.params {
		write_type_key(&b, param)
		strings.write_byte(&b, ',')
	}
	strings.write_byte(&b, '>')
	write_type_key(&b, signature.result)
	return strings.to_string(b)
}

@(private)
write_type_key :: proc(b: ^strings.Builder, type: ir.Type) {
	strings.write_int(b, int(type.kind))
	strings.write_byte(b, ':')
	strings.write_int(b, int(type.nullish))
	strings.write_byte(b, ':')
	strings.write_int(b, int(type.layout))
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

@(private)
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
@(private)
memo_of :: proc(low: ^Lowering, types: []check.Type) -> ^Type_Memo {
	for &memo in low.memos {
		if raw_data(memo.of) == raw_data(types) {
			return &memo
		}
	}
	panic("a type table that belongs to no check result")
}
