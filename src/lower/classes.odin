package lower

import "core:slice"
import "core:strings"

import "../abi"
import "../check"
import "../ir"

/*
The classes of types that need one layout or one signature, since check let a value of one flow
where another was expected, and the views of the types only read through. build_classes makes them
over the whole program before any body is built; types.odin reads them where it maps a type.

Widening. A value of type A that check accepted where B was expected is the same object after the
flow, with no copy, as in Node. Where the program writes through B, or through a type B flows into,
A and B need one layout: lower joins their keys into a class before any body is built, and the
class has one slot per field, the kind every member agrees on, the one that may hold null where the
other holds a present reference, the one of several layouts where the other holds one, or Tagged
where they differ otherwise. A read through the narrower type then checks the tag, the layout, or
for null (objects.odin). Where nothing writes through B, A keeps its layout, and B is a view: its
places hold a cell of its own layout or of any that flows in, a reference of several layouts whose
reads test the layout and box what it holds (Check_Result.writes, build_classes). So the narrow
side pays nothing for a flow only read.

Arrays. An array layout is the kind of its element slot. An array that check accepted where an
array of a wider element was expected is the same array after the flow too, so the two types need
one slot where the wide one is written through, push, pop and sort included, and are a view
otherwise. Their classes are built the way the widening classes are, joining the slot kinds, and
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

// Classes is a union-find over string keys, each node holding a value. join_classes gives every
// root the join of its class, and class_value answers it for any key of the class. The keys are
// strings, so the Type_IDs of two checkers never meet.
Classes :: struct($V: typeid) {
	nodes:  map[string]int,
	keys:   [dynamic]string, // by node
	links:  [dynamic]int,
	values: [dynamic]V,
	joined: bool, // join_classes ran, so what class_value answers is final
}

@(private)
make_classes :: proc($V: typeid) -> Classes(V) {
	return {
		nodes = make(map[string]int, context.temp_allocator),
		keys = make([dynamic]string, context.temp_allocator),
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
	append(&classes.keys, key)
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

// build_classes joins the keys of the widenings a write may reach, objects first, then arrays, then
// the signatures of every pair of function types a flow recorded. The key of an array names the
// class fields of an object element, and the key of a signature the full IR types, layouts
// included, so each pass comes after the classes it reads are final.
@(private)
build_classes :: proc(low: ^Lowering, results: []check.Check_Result) {
	written := written_types(results)
	objects := object_flows(low, results)
	for result, i in results {
		for id in written[i] {
			if node, found := object_node(low, result.types, id, &objects); found {
				expose(&objects, node)
			}
		}
	}
	for {
		join_exposed(&low.objects, &objects, join_slots)
		if object_views(low, &objects) {
			break
		}
	}

	arrays := array_flows(low, results)
	for result, i in results {
		for id in written[i] {
			if node, found := array_node(low, result.types, id, &arrays); found {
				expose(&arrays, node)
			}
		}
	}
	for {
		join_exposed(&low.arrays, &arrays, join_slot_kind)
		if array_views(low, &arrays) {
			break
		}
	}

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

// written_types answers, for each check result, the types a write stores into: the one written
// through, and every object and array type the stored value may hold, however deep, since `o.p = x`
// through `{p: X}` puts an X where a `{p: Y}` that flowed in reads a Y unchecked.
@(private)
written_types :: proc(results: []check.Check_Result) -> [][]check.Type_ID {
	written := make([][]check.Type_ID, len(results), context.temp_allocator)
	for result, i in results {
		found := make([dynamic]check.Type_ID, context.temp_allocator)
		seen := make(map[check.Type_ID]bool, context.temp_allocator)
		for write in result.writes {
			for member in members_of(result.types, write.through) {
				append(&found, member)
			}
			if write.slot != check.VOID {
				reach_stored(result.types, write.slot, &found, &seen)
			}
		}
		written[i] = found[:]
	}
	return written
}

@(private)
reach_stored :: proc(
	types: []check.Type,
	id: check.Type_ID,
	found: ^[dynamic]check.Type_ID,
	seen: ^map[check.Type_ID]bool,
) {
	if seen[id] {
		return
	}
	seen[id] = true
	#partial switch v in types[id] {
	case check.Object:
		append(found, id)
		for field in v.fields {
			reach_stored(types, field.type, found, seen)
		}
	case check.Array:
		append(found, id)
		reach_stored(types, v.element, found, seen)
	case check.Union:
		for member in v.members {
			reach_stored(types, member, found, seen)
		}
	}
}

// Flows is the graph of the widenings between the nodes of one kind of class, with what the own
// type of each node declares its slots hold. An exposed node is one a write may reach a cell of.
@(private)
Flows :: struct($H: typeid) {
	into:    map[int][dynamic]int, // by node, the other nodes that flow into it, each once
	held:    map[int]H,
	exposed: map[int]bool,
}

@(private)
object_flows :: proc(low: ^Lowering, results: []check.Check_Result) -> Flows([]ir.Type) {
	flows := make_flows([]ir.Type)
	for result in results {
		for widening in result.widenings {
			source, source_ok := object_node(low, result.types, widening.source, &flows)
			target, target_ok := object_node(low, result.types, widening.target, &flows)
			if source_ok && target_ok {
				add_flow(&flows, source, target)
			}
		}
	}
	return flows
}

@(private)
array_flows :: proc(low: ^Lowering, results: []check.Check_Result) -> Flows(ir.Type) {
	flows := make_flows(ir.Type)
	for result in results {
		for widening in result.widenings {
			source, source_ok := array_node(low, result.types, widening.source, &flows)
			target, target_ok := array_node(low, result.types, widening.target, &flows)
			if source_ok && target_ok {
				add_flow(&flows, source, target)
			}
		}
	}
	return flows
}

@(private)
make_flows :: proc($H: typeid) -> Flows(H) {
	return {
		into = make(map[int][dynamic]int, context.temp_allocator),
		held = make(map[int]H, context.temp_allocator),
		exposed = make(map[int]bool, context.temp_allocator),
	}
}

@(private)
add_flow :: proc(flows: ^Flows($H), source, target: int) {
	if source == target {
		return
	}
	sources := flows.into[target] or_else make([dynamic]int, context.temp_allocator)
	if !slice.contains(sources[:], source) {
		append(&sources, source)
	}
	flows.into[target] = sources
}

// expose marks a node and every node that flows into it, through any number of flows: a cell of
// any of them may sit in a place of the node's type.
@(private)
expose :: proc(flows: ^Flows($H), node: int) {
	if flows.exposed[node] {
		return
	}
	flows.exposed[node] = true
	// A local: ranging over the map element itself takes its address, nil for a missing key.
	sources := flows.into[node]
	for source in sources {
		expose(flows, source)
	}
}

// join_exposed joins the two ends of every flow into an exposed node, as every flow was joined
// before writes were told apart from reads. Called again after more are exposed, it only adds.
@(private)
join_exposed :: proc(classes: ^Classes($V), flows: ^Flows($H), join: proc(a, b: V) -> V) {
	for target, sources in flows.into {
		if flows.exposed[target] {
			for source in sources {
				class_union(classes, source, target)
			}
		}
	}
	join_classes(classes, join)
}

// viewed answers the nodes other nodes flow into and that no write reaches, each with itself and
// the nodes that flow into it, through any number of flows.
@(private)
viewed :: proc(flows: ^Flows($H)) -> map[int][dynamic]int {
	out := make(map[int][dynamic]int, context.temp_allocator)
	for node in flows.into {
		if flows.exposed[node] {
			continue
		}
		sources := make([dynamic]int, context.temp_allocator)
		seen := make(map[int]bool, context.temp_allocator)
		append(&sources, node)
		seen[node] = true
		for i := 0; i < len(sources); i += 1 {
			into := flows.into[sources[i]]
			for source in into {
				if !seen[source] {
					seen[source] = true
					append(&sources, source)
				}
			}
		}
		out[node] = sources
	}
	return out
}

// Object_View is one layout a place of an object type only read through may hold, with what each
// field holds as the types of that layout declare it: that tells what a reference slot holds.
Object_View :: struct {
	slots: []ir.Slot,
	held:  []ir.Type,
}

// object_views gives each object key only read through, which others flow into, the layouts its
// places hold, its own first. Two that differ only in what a reference slot holds, which a test
// of the header cannot tell apart, expose the key instead, and false joins the classes again.
@(private)
object_views :: proc(low: ^Lowering, flows: ^Flows([]ir.Type)) -> (settled: bool) {
	clear(&low.object_views)
	settled = true
	for node, sources in viewed(flows) {
		views := make([dynamic]Object_View, context.temp_allocator)
		apart := true
		for source in sources {
			root := class_root(&low.objects, source)
			view := Object_View {
				slots = low.objects.values[root],
				held  = flows.held[source],
			}
			apart &&= add_object_view(&views, view)
		}
		if !apart {
			expose(flows, node)
			settled = false
		} else if len(views) > 1 {
			slice.sort_by(views[1:], proc(a, b: Object_View) -> bool {
				return slots_key(a.slots) < slots_key(b.slots)
			})
			low.object_views[low.objects.keys[node]] = views[:]
		}
	}
	return settled
}

// add_object_view answers false where the views already hold the layout with another kind of
// reference in one of its slots.
@(private)
add_object_view :: proc(views: ^[dynamic]Object_View, view: Object_View) -> bool {
	for one in views {
		if !slice.equal(one.slots, view.slots) {
			continue
		}
		for slot, i in view.slots {
			if held, _ := slot_reference(slot.kind); held.kind == .Ref {
				if one.held[i].kind != view.held[i].kind {
					return false
				}
			}
		}
		return true
	}
	append(views, view)
	return true
}

// Array_View is one array layout a place of an array type only read through may hold, with what its
// element holds as the types of that layout declare it.
Array_View :: struct {
	element: abi.Slot_Kind,
	held:    ir.Type,
}

// array_views is object_views for arrays.
@(private)
array_views :: proc(low: ^Lowering, flows: ^Flows(ir.Type)) -> (settled: bool) {
	clear(&low.array_views)
	settled = true
	for node, sources in viewed(flows) {
		views := make([dynamic]Array_View, context.temp_allocator)
		apart := true
		for source in sources {
			view := Array_View {
				element = low.arrays.values[class_root(&low.arrays, source)],
				held    = flows.held[source],
			}
			apart &&= add_array_view(&views, view)
		}
		if !apart {
			expose(flows, node)
			settled = false
		} else if len(views) > 1 {
			slice.sort_by(views[1:], proc(a, b: Array_View) -> bool {
				return a.element < b.element
			})
			low.array_views[low.arrays.keys[node]] = views[:]
		}
	}
	return settled
}

@(private)
add_array_view :: proc(views: ^[dynamic]Array_View, view: Array_View) -> bool {
	for one in views {
		if one.element != view.element {
			continue
		}
		held, _ := slot_reference(view.element)
		return held.kind != .Ref || one.held.kind == view.held.kind
	}
	append(views, view)
	return true
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
		if _, is_view := object_view(low, types, v); !is_view {
			slots := class_slots(low, types, v)
			append(&wanted.objects, Object_Shape{key = slots_key(slots), slots = slots})
		}
	case check.Array:
		if _, is_view := array_view(low, types, v); !is_view {
			wanted.arrays += {array_slot(low, types, v)}
		}
	case check.Union:
		if member, _, held := nullable_member(types, v); held {
			collect_layout(low, types, member, wanted)
		}
	}
	return true
}

// object_node answers the node of an object type's key, and notes what its fields hold. A type with
// no representation takes part in nothing: it is reported where it is used.
@(private)
object_node :: proc(
	low: ^Lowering,
	types: []check.Type,
	id: check.Type_ID,
	flows: ^Flows([]ir.Type),
) -> (
	node: int,
	ok: bool,
) {
	object := types[id].(check.Object) or_return
	slots := object_slots(types, object) or_return
	node = class_node(&low.objects, object_key(types, object, slots), slots)
	flows.held[node] = object_held(types, object)
	return node, true
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
	flows: ^Flows(ir.Type),
) -> (
	node: int,
	ok: bool,
) {
	array := types[id].(check.Array) or_return
	slot := element_slot(types, array.element) or_return
	node = class_node(&low.arrays, element_key(low, types, array.element), slot)
	flows.held[node], _ = shallow_type(types, array.element)
	return node, true
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
		strings.write_string(b, object_key(types, v, class_slots(low, types, v)))
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
