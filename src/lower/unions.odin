package lower

import "core:slice"

import "../abi"
import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../source"

/*
Unions and `any`: the tagged value. A value whose type can hold more than one kind of value is the
tag and the payload of requirements 3.4, and every move out of it into a static type is a check that
fails the program rather than read it wrong (requirements 3.8).

A tagged value becomes static in one way only. A read check narrowed (a narrowed name, `x!`, an
`any` narrowed by `typeof`) is unboxed where lower_expression hands it over, since the node holds
the narrower type: narrowed tests the tag, and for an object or an array the layout, then unboxes.
Every other move out of a tagged value is an operation of its own: coerce (an `any`, or a union of
objects, going into a static type), `as`, `x!`, a tag test for `typeof`, `null` and `undefined`,
the runtime rows for `typeof` as a value, `===`, truthiness and ToString, and a dispatch over the
layouts for a field of a union of objects.

An `any` never becomes a function: only its tag could be checked, never its signature, and a closure
called through the wrong signature is a wrong program. check refuses what JavaScript would do to an
`any` by converting it or looking something up at run time; lower refuses the one move only a flow
shows (flow_intact) and `as`.

The checks are shallow. A layout is a shape, so two object types of one layout, such as
`{kind: "a", v: number}` and `{kind: "b", v: number}`, pass for each other, and an `as` to a literal
type checks the tag only.
*/

// unbox_checked reads a tagged value as a static type, after a check that fails with `error` where
// the value holds another kind, or for an object or an array another layout. A closure is checked
// by its tag only: a function in a union came in through a flow check recorded, so its signature
// class is the member's.
@(private)
unbox_checked :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	want: ir.Type,
	error: abi.Runtime_Error,
	span: source.Span,
) -> ir.Value_ID {
	tag, has_tag := tag_of(want)
	if !has_tag {
		return value
	}
	fits := tag_test(s, value, {tag}, span)
	unboxed := ir.add_block(&s.fb)
	failed := ir.add_block(&s.fb)
	ir.emit(
		&s.fb,
		ir.VOID,
		ir.Branch{condition = fits, then_block = unboxed, else_block = failed},
		span,
	)
	fail_block(s, failed, error, span)

	ir.use_block(&s.fb, unboxed)
	result := ir.emit(&s.fb, want, ir.Unbox{value = value}, span)
	if want.kind == .Ref {
		layout := ir.Layout_Test {
			cell   = result,
			layout = want.layout,
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
	return result
}

// tag_of is the tag a value of a static type has once it is boxed; an array is an object there.
@(private)
tag_of :: proc(type: ir.Type) -> (abi.Tag, bool) {
	switch type.kind {
	case .F64:
		return .Number, true
	case .Bool:
		return .Boolean, true
	case .Str:
		return .String, true
	case .Ref:
		return .Object, true
	case .Closure:
		return .Function, true
	case .Void, .Tagged:
	}
	return .Undefined, false
}

// narrowed keeps the promise of lower_expression: a tagged value for a node check typed narrower is
// unboxed into the node's type, and fails the program where the value holds something else, which
// only a value that came through `any`, or changed after the test that narrowed it, can do.
// representation comes first, so a node that stays tagged interns nothing.
@(private)
narrowed :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	id: ast.Node_ID,
	span: source.Span,
) -> ir.Value_ID {
	if value == ir.NO_VALUE || value_type(s, value) != ir.TAGGED {
		return value
	}
	kind, ok := representation(s.types, s.typed.node_types[id])
	if !ok || kind == .Tagged || kind == .Void {
		return value
	}
	return unbox_checked(s, value, node_type(s, id), .Tagged_Holds_Other_Kind, span)
}

// typeof_tags is the set of tags whose values `typeof` answers the word for. "bigint" and "symbol"
// name no value of v1, and `==` still lets a program compare with them.
@(private)
typeof_tags :: proc(word: string) -> (ir.Tag_Set, bool) {
	switch word {
	case "undefined":
		return {.Undefined}, true
	case "object":
		return {.Object, .Null}, true
	case "boolean":
		return {.Boolean}, true
	case "number":
		return {.Number}, true
	case "string":
		return {.String}, true
	case "function":
		return {.Function}, true
	}
	return {}, false
}

// members_of lists the members of a union, or the type itself for any other.
@(private)
members_of :: proc(types: []check.Type, id: check.Type_ID) -> []check.Type_ID {
	if union_type, is_union := types[id].(check.Union); is_union {
		return union_type.members
	}
	out := make([]check.Type_ID, 1, context.temp_allocator)
	out[0] = id
	return out
}

// `typeof`.

// lower_typeof answers the word for the type the operand already has, and asks the runtime for the
// word of a tagged value. `typeof x === "number"` never gets here: it is a tag test
// (lower_typeof_test).
@(private)
lower_typeof :: proc(s: ^Func_State, operand: ast.Node_ID, span: source.Span) -> ir.Value_ID {
	if is_tagged(s, operand) {
		value := lower_expression(s, operand)
		if value == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		call := ir.Call_Runtime {
			export = .Value_Typeof,
			args   = {value},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	}
	word := typeof_word(s, operand)
	if word == "" {
		type := s.typed.node_types[operand]
		return later(s, span, construct_text(s.types, type))
	}
	evaluate_typeof_operand(s, operand)
	return ir.emit(
		&s.fb,
		ir.STR,
		ir.Const_String{text = ir.intern_string(&s.low.builder, word)},
		span,
	)
}

// typeof_word is the word `typeof` answers for the static type of its operand, or "" when only the
// tag of a tagged value could tell.
@(private)
typeof_word :: proc(s: ^Func_State, operand: ast.Node_ID) -> string {
	type := s.typed.node_types[operand]
	switch type {
	case check.UNDEFINED, check.VOID:
		return "undefined"
	case check.NULL:
		return "object"
	}
	#partial switch _ in s.types[type] {
	case check.Function, check.Overload:
		return "function"
	}
	kind, _ := representation(s.types, type)
	#partial switch kind {
	case .F64:
		return "number"
	case .Bool:
		return "boolean"
	case .Str:
		return "string"
	case .Ref:
		return "object"
	case .Closure:
		return "function" // a union of function types
	}
	return ""
}

// lower_typeof_test is `typeof E` compared with a string literal by `===`, `!==`, `==` or `!=`,
// which needs no word at run time: a statically typed E answers a constant, a tagged one a test of
// its tag. matched is false for any other comparison. Both sides run in source order, the literal's
// own side only when it is more than a literal.
@(private)
lower_typeof_test :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Binary,
) -> (
	test: ir.Value_ID,
	matched: bool,
) {
	#partial switch node.op {
	case .Strict_Equal, .Strict_Not_Equal, .Equal, .Not_Equal:
	case:
		return ir.NO_VALUE, false
	}
	sides := [2]ast.Node_ID{node.left, node.right}
	operand, word := ast.NO_NODE, ""
	at := -1
	for side, i in sides {
		unary, is_unary := s.tree.nodes[side].variant.(ast.Unary)
		if !is_unary || unary.op != .Typeof {
			continue
		}
		if text, is_word := literal_word(s, sides[1 - i]); is_word {
			operand, word, at = unary.operand, text, i
			break
		}
	}
	if at < 0 {
		return ir.NO_VALUE, false
	}

	span := s.tree.nodes[id].span
	tagged := is_tagged(s, operand)
	value := ir.NO_VALUE
	for side, i in sides {
		switch {
		case i == at && tagged:
			value = lower_expression(s, operand)
		case i == at:
			evaluate_typeof_operand(s, operand)
		case !is_string_literal(s, side):
			lower_effect(s, side)
		}
	}

	if tagged {
		if value == ir.NO_VALUE {
			return ir.NO_VALUE, true
		}
		test = typeof_is(s, value, word, span)
	} else {
		same := typeof_word(s, operand) == word
		test = ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = same}, span)
	}
	if node.op == .Strict_Not_Equal || node.op == .Not_Equal {
		test = negated(s, test, span)
	}
	return test, true
}

// typeof_is tests whether `typeof` of a tagged value answers the word.
@(private)
typeof_is :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	word: string,
	span: source.Span,
) -> ir.Value_ID {
	tags, known := typeof_tags(word)
	if !known {
		return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)
	}
	return tag_test(s, value, tags, span)
}

// evaluate_typeof_operand runs the operand of a `typeof` whose word is known statically: it may
// call something. A name runs nothing, and closures.odin counts `typeof f` as a call, so a nested
// function with no environment has no local to read.
@(private)
evaluate_typeof_operand :: proc(s: ^Func_State, operand: ast.Node_ID) {
	_, is_ident := s.tree.nodes[operand].variant.(ast.Ident)
	names_something := s.typed.node_symbols[operand].symbol != bind.NO_SYMBOL
	if !is_ident && !names_something {
		lower_effect(s, operand)
	}
}

@(private)
is_tagged :: proc(s: ^Func_State, id: ast.Node_ID) -> bool {
	kind, ok := representation(s.types, s.typed.node_types[id])
	return ok && kind == .Tagged
}

// literal_word answers the text of a node check typed as a string literal type.
@(private)
literal_word :: proc(s: ^Func_State, id: ast.Node_ID) -> (string, bool) {
	literal, is_literal := s.types[s.typed.node_types[id]].(check.Literal)
	if !is_literal {
		return "", false
	}
	return literal.value.(string)
}

@(private)
is_string_literal :: proc(s: ^Func_State, id: ast.Node_ID) -> bool {
	_, is_literal := s.tree.nodes[id].variant.(ast.String_Literal)
	return is_literal
}

// Switch_Subject is what the cases of a `switch` compare with. For `switch (typeof x)` of a tagged
// x it holds x, and a case that names a word tests its tag; the word itself is asked of the runtime
// once, at the first case that is no literal, whose test dominates every later one.
@(private)
Switch_Subject :: struct {
	value:     ir.Value_ID,
	type:      check.Type_ID,
	of_tagged: bool, // the subject is `typeof` of a tagged value
	tagged:    ir.Value_ID, // that value, when of_tagged
}

// switch_subject lowers the subject once, before the scope of the cases is entered.
@(private)
switch_subject :: proc(s: ^Func_State, id: ast.Node_ID) -> Switch_Subject {
	subject := Switch_Subject {
		value  = ir.NO_VALUE,
		type   = s.typed.node_types[id],
		tagged = ir.NO_VALUE,
	}
	if unary, is_unary := s.tree.nodes[id].variant.(ast.Unary); is_unary && unary.op == .Typeof {
		if is_tagged(s, unary.operand) {
			subject.of_tagged = true
			subject.tagged = lower_expression(s, unary.operand)
			return subject
		}
	}
	subject.value = lower_expression(s, id)
	return subject
}

// typeof_case_test answers the test of a case of `switch (typeof x)` for a tagged x, and false for
// matched when the case is no string literal and needs the word itself.
@(private)
typeof_case_test :: proc(
	s: ^Func_State,
	subject: ^Switch_Subject,
	value: ast.Node_ID,
) -> (
	test: ir.Value_ID,
	matched: bool,
) {
	span := s.tree.nodes[value].span
	word, is_word := literal_word(s, value)
	if !is_word {
		if subject.value == ir.NO_VALUE && subject.tagged != ir.NO_VALUE {
			call := ir.Call_Runtime {
				export = .Value_Typeof,
				args   = {subject.tagged},
			}
			subject.value = ir.emit(&s.fb, ir.STR, call, span)
		}
		return ir.NO_VALUE, false
	}
	if !is_string_literal(s, value) {
		lower_effect(s, value)
	}
	if subject.tagged == ir.NO_VALUE {
		// The subject was reported where it stands.
		return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span), true
	}
	return typeof_is(s, subject.tagged, word, span), true
}

// Equality and truthiness.

// compare_tagged is `===` or `!==` with a tagged side. Against a side typed `null` or `undefined`
// it tests the tag of the other; anything else goes to the runtime, both sides boxed.
@(private)
compare_tagged :: proc(
	s: ^Func_State,
	op: ir.Compare_Op,
	values: [2]ir.Value_ID,
	types: [2]check.Type_ID,
	span: source.Span,
) -> ir.Value_ID {
	test := ir.NO_VALUE
	for type, i in types {
		other := values[1 - i]
		nullish := type == check.NULL || type == check.UNDEFINED
		if !nullish || value_type(s, other) != ir.TAGGED {
			continue
		}
		tag := ir.Tag_Set{.Null} if type == check.NULL else ir.Tag_Set{.Undefined}
		test = tag_test(s, other, tag, span)
		break
	}
	if test == ir.NO_VALUE {
		a := coerce(s, values[0], ir.TAGGED, span)
		b := coerce(s, values[1], ir.TAGGED, span)
		if a == ir.NO_VALUE || b == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		call := ir.Call_Runtime {
			export = .Value_Equal,
			args   = {a, b},
		}
		test = ir.emit(&s.fb, ir.BOOL, call, span)
	}
	if op == .Not_Equal {
		return negated(s, test, span)
	}
	return test
}

// truthy_tagged tests a tagged value. One whose members are all nullish or references is true
// exactly when it is neither null nor undefined, which is one tag test: the `while (node)` over a
// linked list calls nothing.
@(private)
truthy_tagged :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	type: check.Type_ID,
	span: source.Span,
) -> ir.Value_ID {
	if type != check.ERROR && nullish_or_reference(s.types, type) {
		return negated(s, tag_test(s, value, {.Undefined, .Null}, span), span)
	}
	call := ir.Call_Runtime {
		export = .Value_To_Boolean,
		args   = {value},
	}
	return ir.emit(&s.fb, ir.BOOL, call, span)
}

@(private)
nullish_or_reference :: proc(types: []check.Type, id: check.Type_ID) -> bool {
	for member in members_of(types, id) {
		switch member {
		case check.NULL, check.UNDEFINED, check.VOID:
			continue
		}
		#partial switch _ in types[member] {
		case check.Object, check.Array, check.Function, check.Overload:
			continue
		}
		return false
	}
	return true
}

// `as`.

// lower_as converts the way requirements 3.8 allows: a widening boxes or changes nothing, and a
// narrowing of a tagged value checks what it holds, failing with Type_Assertion. An `any` or an
// `unknown` never becomes a type that holds a function.
@(private)
lower_as :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.As) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	value := lower_expression(s, node.expr)
	from, to := s.typed.node_types[node.expr], s.typed.node_types[id]
	if (from == check.ANY || from == check.UNKNOWN) && holds_function(s.types, to) {
		what := "any" if from == check.ANY else "unknown"
		report(s.low, .Any_Operation, span, "become a function", what)
		return ir.NO_VALUE
	}
	target := node_type(s, id)
	if value == ir.NO_VALUE || value_type(s, value) != ir.TAGGED || target == ir.VOID {
		return coerce(s, value, target, span)
	}
	if target != ir.TAGGED {
		return unbox_checked(s, value, target, .Type_Assertion, span)
	}
	check_members(s, value, to, span)
	return value
}

// check_members fails the program unless a tagged value holds a member of the union: the tag of a
// primitive or a function member, or an object of the layout of an object or an array member. An
// `any` member admits everything, and a literal member its whole kind.
@(private)
check_members :: proc(s: ^Func_State, value: ir.Value_ID, type: check.Type_ID, span: source.Span) {
	tags: ir.Tag_Set
	layouts := make([dynamic]ir.Layout_ID, 0, 4, context.temp_allocator)
	for member in members_of(s.types, type) {
		switch member {
		case check.ANY, check.UNKNOWN:
			return
		case check.NULL:
			tags += {.Null}
			continue
		case check.UNDEFINED, check.VOID:
			tags += {.Undefined}
			continue
		}
		member_type, ok := ir_type(s.low, s.types, member)
		if !ok {
			continue // a type with no representation was reported where it was declared
		}
		if member_type.kind == .Ref {
			if !slice.contains(layouts[:], member_type.layout) {
				append(&layouts, member_type.layout)
			}
		} else if tag, has_tag := tag_of(member_type); has_tag {
			tags += {tag}
		}
	}

	if tags == {} && len(layouts) == 0 {
		return
	}
	passed := ir.add_block(&s.fb)
	failed := ir.add_block(&s.fb)
	if tags != {} {
		objects := failed
		if len(layouts) > 0 {
			objects = ir.add_block(&s.fb)
		}
		fits := tag_test(s, value, tags, span)
		branch := ir.Branch {
			condition  = fits,
			then_block = passed,
			else_block = objects,
		}
		ir.emit(&s.fb, ir.VOID, branch, span)
		if objects != failed {
			ir.use_block(&s.fb, objects)
		}
	}
	if len(layouts) > 0 {
		hits := make([]ir.Block_ID, len(layouts), context.temp_allocator)
		slice.fill(hits, passed)
		dispatch_layouts(s, value, layouts[:], hits, failed, span)
	}
	fail_block(s, failed, .Type_Assertion, span)
	ir.use_block(&s.fb, passed)
}

// dispatch_layouts ends the current block with a branch on the object a tagged value holds: to
// hits[i] where it has layouts[i], and to failed where it is no object or has none of them.
@(private)
dispatch_layouts :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	layouts: []ir.Layout_ID,
	hits: []ir.Block_ID,
	failed: ir.Block_ID,
	span: source.Span,
) {
	is_object := tag_test(s, value, {.Object}, span)
	chain := ir.add_block(&s.fb)
	ir.emit(
		&s.fb,
		ir.VOID,
		ir.Branch{condition = is_object, then_block = chain, else_block = failed},
		span,
	)
	ir.use_block(&s.fb, chain)
	// Any of the layouts types the reference well enough for a test that reads only its header.
	cell := ir.emit(&s.fb, ir.ref(layouts[0]), ir.Unbox{value = value}, span)
	for layout, i in layouts {
		next := failed
		if i + 1 < len(layouts) {
			next = ir.add_block(&s.fb)
		}
		test := ir.emit(&s.fb, ir.BOOL, ir.Layout_Test{cell = cell, layout = layout}, span)
		ir.emit(
			&s.fb,
			ir.VOID,
			ir.Branch{condition = test, then_block = hits[i], else_block = next},
			span,
		)
		if next != failed {
			ir.use_block(&s.fb, next)
		}
	}
}

// holds_function says whether a value of the type may hold a function anywhere: the type itself, a
// member, a field or an element. An interface that holds itself is walked once.
@(private)
holds_function :: proc(types: []check.Type, id: check.Type_ID) -> bool {
	seen := make([dynamic]check.Type_ID, 0, 8, context.temp_allocator)
	return holds_function_in(types, id, &seen)
}

@(private)
holds_function_in :: proc(
	types: []check.Type,
	id: check.Type_ID,
	seen: ^[dynamic]check.Type_ID,
) -> bool {
	#partial switch v in types[id] {
	case check.Function, check.Overload:
		return true
	case check.Union:
		for member in v.members {
			if holds_function_in(types, member, seen) {
				return true
			}
		}
	case check.Array:
		return holds_function_in(types, v.element, seen)
	case check.Object:
		if slice.contains(seen[:], id) {
			return false
		}
		append(seen, id)
		for field in v.fields {
			if holds_function_in(types, field.type, seen) {
				return true
			}
		}
	}
	return false
}

// Fields of a union of objects.

// Union_Field is how the members of one layout hold the field: its slot, and the type a read gives.
@(private)
Union_Field :: struct {
	layout: ir.Layout_ID,
	field:  i32,
	type:   ir.Type,
	mixed:  bool, // the members of the layout disagree on the field's type
}

// Union_Field_Place is a field of a value typed as a union of objects: one entry per layout its
// members have. type is what a read answers.
@(private)
Union_Field_Place :: struct {
	value:   ir.Value_ID,
	members: []Union_Field,
	type:    ir.Type,
}

// is_object_union says whether a type is a union whose every member is an object type.
@(private)
is_object_union :: proc(types: []check.Type, id: check.Type_ID) -> bool {
	union_type, is_union := types[id].(check.Union)
	if !is_union {
		return false
	}
	for member in union_type.members {
		if _, is_object := types[member].(check.Object); !is_object {
			return false
		}
	}
	return true
}

// union_field_place groups the members by layout. A layout whose members agree on the field's IR
// type reads it as that type. One whose members disagree reads the slot at its own kind, which
// works for a tagged slot and for a reference slot where every member holds an object or an array,
// since the box of either is an object; anything else is reported. A read of the whole answers the
// type the members agree on, or a tagged value, as check has the field.
@(private)
union_field_place :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	union_type: check.Type_ID,
	name: string,
	span: source.Span,
) -> (
	place: Place,
	ok: bool,
) {
	Member_Field :: struct {
		layout:   ir.Layout_ID,
		field:    i32,
		type:     ir.Type,
		declared: check.Type_ID,
	}
	members := members_of(s.types, union_type)
	found := make([]Member_Field, len(members), context.temp_allocator)
	for member, i in members {
		object_type, representable := ir_type(s.low, s.types, member)
		if !representable {
			later(s, span, construct_text(s.types, member))
			return nil, false
		}
		object := s.types[member].(check.Object)
		field, type := field_in(s, object_type.layout, object, name) or_return
		declared, _ := find_field(object, name)
		found[i] = {object_type.layout, field, type, declared.type}
	}

	// check holds a union of two object types tagged even where they share a layout, so members that
	// read a reference agree only on one declared type.
	agree := true
	for member in found[1:] {
		same := member.type == found[0].type
		if member.type.kind == .Ref {
			same &&= member.declared == found[0].declared
		}
		agree &&= same
	}
	out := Union_Field_Place {
		value = value,
		type  = found[0].type if agree else ir.TAGGED,
	}

	groups := make([dynamic]Union_Field, 0, len(found), context.temp_allocator)
	for member in found {
		index := -1
		for group, i in groups {
			if group.layout == member.layout {
				index = i
			}
		}
		if index < 0 {
			append(&groups, Union_Field{member.layout, member.field, member.type, false})
			continue
		}
		group := &groups[index]
		if group.type == member.type {
			continue
		}
		// Two objects or arrays in a reference slot are read as the first member's type and boxed,
		// and the box is an object either way.
		group.mixed = true
		slot := s.low.builder.layouts[group.layout].fields[group.field].kind
		if slot == .Tagged {
			group.type = ir.TAGGED
		} else if group.type.kind != .Ref || member.type.kind != .Ref {
			later(s, span, "a field whose representation differs across the members of a union")
			return nil, false
		}
	}
	out.members = groups[:]
	return out, true
}

@(private)
load_union_field :: proc(
	s: ^Func_State,
	place: Union_Field_Place,
	span: source.Span,
) -> ir.Value_ID {
	hits, failed := union_dispatch(s, place, span)
	join := ir.add_block(&s.fb)
	edges := make([dynamic]Edge, 0, len(hits), context.temp_allocator)
	values := make([dynamic]ir.Value_ID, 0, len(hits), context.temp_allocator)
	complete := true
	for member, i in place.members {
		ir.use_block(&s.fb, hits[i])
		cell := ir.emit(&s.fb, ir.ref(member.layout), ir.Unbox{value = place.value}, span)
		field := Field_Place {
			cell  = cell,
			field = member.field,
			type  = member.type,
		}
		value := coerce(s, load_field(s, field, span), place.type, span)
		complete &&= value != ir.NO_VALUE
		append(&edges, here(s))
		append(&values, value)
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
	}
	fail_block(s, failed, .Tagged_Holds_Other_Kind, span)
	merged := join_values(s, join, edges[:], values[:], place.type, span)
	return merged if complete else ir.NO_VALUE
}

// store_union_field unboxes the object again in every arm: the references a load unboxed do not
// reach the store of a compound assignment, which comes after the join of the load.
@(private)
store_union_field :: proc(
	s: ^Func_State,
	place: Union_Field_Place,
	value: ir.Value_ID,
	span: source.Span,
) -> bool {
	for member in place.members {
		slot := s.low.builder.layouts[member.layout].fields[member.field].kind
		if member.mixed && slot != .Tagged {
			later(s, span, "writing a field whose type differs across the members of a union")
			return false
		}
	}
	hits, failed := union_dispatch(s, place, span)
	after := ir.add_block(&s.fb)
	edges := make([dynamic]Edge, 0, len(hits), context.temp_allocator)
	stored := true
	for member, i in place.members {
		ir.use_block(&s.fb, hits[i])
		cell := ir.emit(&s.fb, ir.ref(member.layout), ir.Unbox{value = place.value}, span)
		field := Field_Place {
			cell  = cell,
			field = member.field,
			type  = member.type,
		}
		stored &&= store_field(s, field, value, span)
		append(&edges, here(s))
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = after}, span)
	}
	fail_block(s, failed, .Tagged_Holds_Other_Kind, span)
	open_join(s, after, edges[:], span)
	return stored
}

// union_dispatch branches on the layout of the object and answers a block for each member entry of
// the place, and the block that fails.
@(private)
union_dispatch :: proc(
	s: ^Func_State,
	place: Union_Field_Place,
	span: source.Span,
) -> (
	hits: []ir.Block_ID,
	failed: ir.Block_ID,
) {
	layouts := make([]ir.Layout_ID, len(place.members), context.temp_allocator)
	hits = make([]ir.Block_ID, len(place.members), context.temp_allocator)
	for member, i in place.members {
		layouts[i] = member.layout
		hits[i] = ir.add_block(&s.fb)
	}
	failed = ir.add_block(&s.fb)
	dispatch_layouts(s, place.value, layouts, hits, failed, span)
	return hits, failed
}

// union_length is the length of a union of strings and arrays. Every array keeps its length where
// a string does, so an array of any of the layouts is read through the first.
@(private)
union_length :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	type: check.Type_ID,
	span: source.Span,
) -> ir.Value_ID {
	has_string := false
	layouts := make([dynamic]ir.Layout_ID, 0, 2, context.temp_allocator)
	for member in members_of(s.types, type) {
		kind, _ := shallow_kind(s.types, member)
		_, is_array := s.types[member].(check.Array)
		switch {
		case kind == .Str:
			has_string = true
		case is_array:
			array_type, ok := ir_type(s.low, s.types, member)
			if !ok {
				return later(s, span, construct_text(s.types, member))
			}
			if !slice.contains(layouts[:], array_type.layout) {
				append(&layouts, array_type.layout)
			}
		case:
			return later(s, span, "the length of this union")
		}
	}

	failed := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	edges := make([dynamic]Edge, 0, 2, context.temp_allocator)
	lengths := make([dynamic]ir.Value_ID, 0, 2, context.temp_allocator)
	if has_string {
		text_block := ir.add_block(&s.fb)
		otherwise := failed
		if len(layouts) > 0 {
			otherwise = ir.add_block(&s.fb)
		}
		is_string := tag_test(s, value, {.String}, span)
		branch := ir.Branch {
			condition  = is_string,
			then_block = text_block,
			else_block = otherwise,
		}
		ir.emit(&s.fb, ir.VOID, branch, span)
		ir.use_block(&s.fb, text_block)
		text := ir.emit(&s.fb, ir.STR, ir.Unbox{value = value}, span)
		append(&lengths, ir.emit(&s.fb, ir.F64, ir.Length{value = text}, span))
		append(&edges, here(s))
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
		if otherwise != failed {
			ir.use_block(&s.fb, otherwise)
		}
	}
	if len(layouts) > 0 {
		array_block := ir.add_block(&s.fb)
		hits := make([]ir.Block_ID, len(layouts), context.temp_allocator)
		slice.fill(hits, array_block)
		dispatch_layouts(s, value, layouts[:], hits, failed, span)
		ir.use_block(&s.fb, array_block)
		array := ir.emit(&s.fb, ir.ref(layouts[0]), ir.Unbox{value = value}, span)
		append(&lengths, ir.emit(&s.fb, ir.F64, ir.Length{value = array}, span))
		append(&edges, here(s))
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
	}
	fail_block(s, failed, .Tagged_Holds_Other_Kind, span)
	return join_values(s, join, edges[:], lengths[:], ir.F64, span)
}
