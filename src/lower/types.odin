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
and anything that can hold more than one shape at run time is the two-word tagged value.

Two procedures, because deciding and building are two jobs. representation answers the kind alone
and interns nothing, so the decisions ask it: the net under poison, the text of a refusal, typeof.
ir_type interns the layout of an object or an array, and is asked only where a value is built.

A type with no representation answers `false`, and the caller reports Not_Lowered rather than
guessing: a function with a rest parameter, and the generic signatures only the lib declares.

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

Functions. A function value is a closure, whatever its signature, and its signature is the IR types
of its parameters and its result. A function accepted where another function type was expected is
the same closure after the flow, so the two types need one signature, or a call through the second
would pass arguments the first does not take. Signature classes are built the way the widening
classes are, over the whole program: a parameter every member agrees on keeps its type, one they
differ on is Tagged, and so is the result, where a member that returns nothing answers undefined.
A class of void functions has a tagged result as well where one of them returns what a call
answered, which Node passes on (widen_void_results, closures.odin). A function then takes the
arguments of its class and unboxes each into its own type (coerce), and a call gives the class what
it wants and unboxes the answer.
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
	}
	return shallow_kind(types, id)
}

// ir_type answers from the memo of the check result after the first call for a type.
ir_type :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
) -> (
	type: ir.Type,
	ok: bool,
) {
	ensure(low.objects.joined, "an object type is mapped before its widening class is complete")
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
	case check.Function:
		return .Closure, true
	case check.Type_Var, check.Overload:
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
	if joined, found := class_value(&low.objects, slots_key(slots)); found {
		slots = joined
	}
	return ir.object_layout(&low.builder, slots)
}

// Classes.

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

// build_classes joins the shallow keys of every widening of every result, then the signatures of
// every pair of function types a flow recorded. The signatures come second: their key is the full
// IR types of a signature, layouts included, and those are final only once every widening class
// is.
@(private)
build_classes :: proc(low: ^Lowering, results: []check.Check_Result) {
	for result in results {
		for widening in result.widenings {
			source, source_ok := object_node(low, result.types, widening.source)
			target, target_ok := object_node(low, result.types, widening.target)
			if source_ok && target_ok {
				class_union(&low.objects, source, target)
			}
		}
	}
	join_classes(&low.objects, join_slots)

	for result in results {
		for widening in result.widenings {
			source, source_ok := signature_node(low, result.types, widening.source)
			target, target_ok := signature_node(low, result.types, widening.target)
			if source_ok && target_ok {
				class_union(&low.signatures, source, target)
			}
		}
	}
	join_classes(&low.signatures, join_signatures)
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

// Signatures.

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
		if i >= function.required || params[i] == ir.VOID {
			params[i] = ir.TAGGED
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

// signature_node answers the node of a function type's signature.
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

// join_signatures gives a parameter only one member has that member's type. A result of void joined
// with another is tagged like any two results that differ: a call through the class may print
// what it gets back, which is undefined from a member that returns nothing (handed_on).
@(private)
join_signatures :: proc(a, b: Signature) -> Signature {
	join :: proc(x, y: ir.Type) -> ir.Type {
		return x if x == y else ir.TAGGED
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
	strings.write_int(b, int(type.layout))
}

// Memos.

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
