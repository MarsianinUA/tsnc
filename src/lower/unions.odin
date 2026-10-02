package lower

import "core:slice"

import "../abi"
import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../program"
import "../source"

/*
Unions and `any`: the tagged value. A value whose type can hold more than one kind of value is the
tag and the payload of requirements 3.4, and every move out of it into a static type is a check that
fails the program rather than read it wrong (requirements 3.8). A reference with one of null and
undefined is a pointer instead (types.odin), read as present after a test for null (present_checked)
the way a tagged value is unboxed after a test of its tag, and boxed wherever a tag is wanted.

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
	tags := ir.Tag_Set{tag}
	if want.nullish != .None {
		tags += {nullish_tag(want)}
	}
	fits := tag_test(s, value, tags, span)
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
	// Null and undefined carry a payload of 0, which is the null of a reference that may hold one.
	result := ir.emit(&s.fb, want, ir.Unbox{value = value}, span)
	if want.kind != .Ref {
		return result
	}
	done := ir.NO_BLOCK
	cell := result
	if want.nullish != .None {
		null := null_test(s, result, span)
		done = ir.add_block(&s.fb)
		held := ir.add_block(&s.fb)
		ir.emit(
			&s.fb,
			ir.VOID,
			ir.Branch{condition = null, then_block = done, else_block = held},
			span,
		)
		ir.use_block(&s.fb, held)
		cell = present(s, result, span)
	}
	layout := ir.Layout_Test {
		cell   = cell,
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
	if done != ir.NO_BLOCK {
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = done}, span)
		ir.use_block(&s.fb, done)
	}
	return result
}

@(private)
present_checked :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	error: abi.Runtime_Error,
	span: source.Span,
) -> ir.Value_ID {
	fail_if(s, null_test(s, value, span), error, span)
	return present(s, value, span)
}

// present types a reference a test proved not null as present. A present value passes as it is: a
// local that may hold null holds a present reference as it was given.
@(private)
present :: proc(s: ^Func_State, value: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	if value == ir.NO_VALUE || value_type(s, value).nullish == .None {
		return value
	}
	type := ir.non_null(value_type(s, value))
	return ir.emit(&s.fb, type, ir.Non_Null{value = value}, span)
}

@(private)
nullish_tag :: proc(type: ir.Type) -> abi.Tag {
	return .Null if type.nullish == .Null else .Undefined
}

@(private)
may_be_nullish :: proc(type: ir.Type) -> bool {
	return type == ir.TAGGED || type.nullish != .None
}

// nullish_test tests whether a value holds null or undefined, as tags name them. A reference
// that may hold null holds only the one its 0 stands for, and a present one neither.
@(private)
nullish_test :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	tags: ir.Tag_Set,
	span: source.Span,
) -> ir.Value_ID {
	type := value_type(s, value)
	switch {
	case type == ir.TAGGED:
		return tag_test(s, value, tags, span)
	case type.nullish != .None && nullish_tag(type) in tags:
		return null_test(s, value, span)
	}
	return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)
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
	case .I32, .I64:
		unreachable()
	}
	return .Undefined, false
}

// narrowed keeps the promise of lower_expression. A tagged value whose node check typed narrower is
// unboxed into the node's type, and a reference that may hold null whose node is present is read
// as present. Either fails the program where the value holds something else, which only a value
// that came through `any`, or one changed after the test that narrowed it, can do. representation
// comes first, so a node that stays tagged interns nothing.
@(private)
narrowed :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	id: ast.Node_ID,
	span: source.Span,
) -> ir.Value_ID {
	if value == ir.NO_VALUE {
		return value
	}
	have := value_type(s, value)
	if !may_be_nullish(have) {
		return value
	}
	kind, ok := representation(s.types, s.typed.node_types[id])
	if !ok || kind == .Tagged || kind == .Void {
		return value
	}
	want := node_type(s, id)
	if have.nullish != .None && want != ir.non_null(have) {
		return value
	}
	return coerce(s, value, want, span)
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

// lower_typeof answers the word statically where the operand's value has a static representation.
// `typeof x === "number"` never gets here: it is a tag test (lower_typeof_test).
@(private)
lower_typeof :: proc(s: ^Func_State, operand: ast.Node_ID, span: source.Span) -> ir.Value_ID {
	value, word := typeof_operand(s, operand)
	if value != ir.NO_VALUE {
		return typeof_value(s, value, span)
	}
	if word == "" {
		return ir.NO_VALUE // reported where the operand stands
	}
	return string_constant(s, word, span)
}

// typeof_value is the word of a value that may be null or undefined: the runtime's for a tagged
// value, and for a reference one of two words, picked by a test for null.
@(private)
typeof_value :: proc(s: ^Func_State, value: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	type := value_type(s, value)
	if type == ir.TAGGED {
		call := ir.Call_Runtime {
			export = .Value_Typeof,
			args   = {value},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	}
	nullish_word, present_word := typeof_words(type)
	if nullish_word == present_word {
		return string_constant(s, present_word, span)
	}
	nullish := string_constant(s, nullish_word, span)
	present := string_constant(s, present_word, span)
	join := ir.add_block(&s.fb)
	nothing := jump_if(s, null_test(s, value, span), join, span)
	something := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
	return join_values(s, join, {nothing, something}, {nullish, present}, ir.STR, span)
}

@(private)
typeof_words :: proc(type: ir.Type) -> (nullish: string, present: string) {
	nullish = "object" if type.nullish == .Null else "undefined"
	#partial switch type.kind {
	case .Str:
		return nullish, "string"
	case .Closure:
		return nullish, "function"
	}
	return nullish, "object"
}

// typeof_operand evaluates the operand of a `typeof` and answers either a value whose word only
// run time tells, a tagged one or a reference that may hold null, or the word itself. The
// representation the value has decides, never the type check narrowed it to: a call may have
// written the variable after the test that narrowed it. A name whose storage is static is not read,
// since its word is known without it; closures.odin counts `typeof f` as a call, so a nested
// function with no environment has no local to read. A name read before its declaration ran still
// fails, as in Node.
@(private)
typeof_operand :: proc(
	s: ^Func_State,
	operand: ast.Node_ID,
) -> (
	value: ir.Value_ID,
	word: string,
) {
	_, is_ident := s.tree.nodes[operand].variant.(ast.Ident)
	ref := s.typed.node_symbols[operand]
	if ref.symbol != bind.NO_SYMBOL && ref.file != program.LIB {
		stored, _ := symbol_type(s.low, ref.file, ref.symbol)
		if !may_be_nullish(stored) {
			if is_ident && early_use(s.tree, s.bound, operand) {
				check_ready(s, s.bound.node_symbols[operand], s.tree.nodes[operand].span)
			}
			return ir.NO_VALUE, typeof_word(s, operand)
		}
	} else if is_ident || ref.symbol != bind.NO_SYMBOL {
		return ir.NO_VALUE, typeof_word(s, operand) // `undefined`, or a name of the lib
	}
	value = lower_raw(s, operand)
	if value == ir.NO_VALUE {
		return ir.NO_VALUE, ""
	}
	if may_be_nullish(value_type(s, value)) {
		return value, ""
	}
	return ir.NO_VALUE, typeof_word(s, operand)
}

// typeof_word is the word `typeof` answers for the static type of its operand, whose value is
// present where the type may hold null, or "" when only the tag of a tagged value could tell.
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
// which needs no word at run time: an E of a static representation answers a constant, a tagged
// one a test of its tag, and a reference that may hold null a test for null (typeof_is). matched is
// false for any other comparison. Both sides run in source order, the literal's own side only when
// it is more than a literal.
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
	value, static_word := ir.NO_VALUE, ""
	for side, i in sides {
		switch {
		case i == at:
			value, static_word = typeof_operand(s, operand)
		case !is_string_literal(s, side):
			lower_effect(s, side)
		}
	}

	switch {
	case value != ir.NO_VALUE:
		test = typeof_is(s, value, word, span)
	case static_word == "":
		return ir.NO_VALUE, true // reported where the operand stands
	case:
		same := static_word == word
		test = ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = same}, span)
	}
	if node.op == .Strict_Not_Equal || node.op == .Not_Equal {
		test = negated(s, test, span)
	}
	return test, true
}

@(private)
typeof_is :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	word: string,
	span: source.Span,
) -> ir.Value_ID {
	if type := value_type(s, value); type != ir.TAGGED {
		nullish_word, present_word := typeof_words(type)
		switch {
		case (nullish_word == word) == (present_word == word):
			return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = present_word == word}, span)
		case nullish_word == word:
			return null_test(s, value, span)
		}
		return negated(s, null_test(s, value, span), span)
	}
	tags, known := typeof_tags(word)
	if !known {
		return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)
	}
	return tag_test(s, value, tags, span)
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

// Switch_Subject is what the cases of a `switch` compare with. For `switch (typeof x)` where only
// run time tells the word, it holds x, and a case that names a word tests x (typeof_is); the word
// itself is made once, at the first case that is no literal, whose test dominates every later one.
@(private)
Switch_Subject :: struct {
	value:   ir.Value_ID,
	operand: ir.Value_ID, // x, or NO_VALUE
}

// switch_subject lowers the subject once, before the scope of the cases is entered.
@(private)
switch_subject :: proc(s: ^Func_State, id: ast.Node_ID) -> Switch_Subject {
	subject := Switch_Subject {
		value   = ir.NO_VALUE,
		operand = ir.NO_VALUE,
	}
	if unary, is_unary := s.tree.nodes[id].variant.(ast.Unary); is_unary && unary.op == .Typeof {
		value, word := typeof_operand(s, unary.operand)
		if value != ir.NO_VALUE {
			subject.operand = value
		} else if word != "" {
			subject.value = string_constant(s, word, s.tree.nodes[id].span)
		}
		return subject
	}
	subject.value = lower_expression(s, id)
	return subject
}

// typeof_case_test answers the test of a case of `switch (typeof x)` that holds x, and false for
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
		if subject.value == ir.NO_VALUE {
			subject.value = typeof_value(s, subject.operand, span)
		}
		return ir.NO_VALUE, false
	}
	if !is_string_literal(s, value) {
		lower_effect(s, value)
	}
	return typeof_is(s, subject.operand, word, span), true
}

// compare_tagged is `===` or `!==` with a tagged side where compare_references found no null or
// undefined to test for: the runtime compares, both sides boxed. A type check narrowed a side to
// never decides: a call may have written the variable since the test that narrowed it.
@(private)
compare_tagged :: proc(
	s: ^Func_State,
	op: ir.Compare_Op,
	values: [2]ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	a := coerce(s, values[0], ir.TAGGED, span)
	b := coerce(s, values[1], ir.TAGGED, span)
	if a == ir.NO_VALUE || b == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	call := ir.Call_Runtime {
		export = .Value_Equal,
		args   = {a, b},
	}
	test := ir.emit(&s.fb, ir.BOOL, call, span)
	if op == .Not_Equal {
		return negated(s, test, span)
	}
	return test
}

// compare_references answers `===` where a side is null or undefined itself (nullish_tags) and the
// other tagged or a reference, or a side is a reference that may hold null: a test of the tag or for
// null, an answer known before anything runs, the addresses of two objects or two functions, or the
// tests of compare_nullable. Against a tagged side both go to the runtime boxed. handled = false
// leaves the comparison to the caller.
@(private)
compare_references :: proc(
	s: ^Func_State,
	values: [2]ir.Value_ID,
	span: source.Span,
) -> (
	test: ir.Value_ID,
	handled: bool,
) {
	for value, i in values {
		other := values[1 - i]
		tags, nullish := nullish_tags(s, value)
		if !nullish {
			continue
		}
		if type := value_type(s, other); type == ir.TAGGED || ir.is_reference(type) {
			return nullish_test(s, other, tags, span), true
		}
	}
	a, b := value_type(s, values[0]), value_type(s, values[1])
	if a.nullish == .None && b.nullish == .None {
		return ir.NO_VALUE, false
	}
	if !ir.is_reference(a) || ir.non_null(a) != ir.non_null(b) {
		return compare_tagged(s, .Equal, values, span), true
	}
	same_null := a.nullish == b.nullish || a.nullish == .None || b.nullish == .None
	if a.kind != .Str && same_null {
		compare := ir.Compare {
			op    = .Equal,
			left  = values[0],
			right = values[1],
		}
		return ir.emit(&s.fb, ir.BOOL, compare, span), true
	}
	return compare_nullable(s, values, span), true
}

// compare_nullable is `===` of two references of one type, either of which may hold null: a null
// side equals only a null that stands for the same nullish, and two present sides compare as
// strings or by address.
@(private)
compare_nullable :: proc(
	s: ^Func_State,
	values: [2]ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	types := [2]ir.Type{value_type(s, values[0]), value_type(s, values[1])}
	nulls := [2]ir.Value_ID{ir.NO_VALUE, ir.NO_VALUE}
	for type, i in types {
		if type.nullish != .None {
			nulls[i] = null_test(s, values[i], span)
		}
	}
	join := ir.add_block(&s.fb)
	edges := make([dynamic]Edge, 0, 3, context.temp_allocator)
	answers := make([dynamic]ir.Value_ID, 0, 3, context.temp_allocator)
	no := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)
	if nulls[0] != ir.NO_VALUE {
		// A null first side equals a second that is null too and stands for the same nullish.
		append(&answers, nulls[1] if types[1].nullish == types[0].nullish else no)
		append(&edges, jump_if(s, nulls[0], join, span))
	}
	if nulls[1] != ir.NO_VALUE {
		append(&answers, no)
		append(&edges, jump_if(s, nulls[1], join, span))
	}
	left, right := present(s, values[0], span), present(s, values[1], span)
	equal: ir.Value_ID
	if types[0].kind == .Str {
		equal = strings_equal(s, left, right, span)
	} else {
		equal = ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Equal, left = left, right = right}, span)
	}
	append(&edges, here(s))
	append(&answers, equal)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)
	return join_values(s, join, edges[:], answers[:], ir.BOOL, span)
}

// nullish_tags answers the tag of a value that is null or undefined whatever runs: the constant, or
// the answer of a call typed void.
@(private)
nullish_tags :: proc(s: ^Func_State, value: ir.Value_ID) -> (tags: ir.Tag_Set, nullish: bool) {
	if value == ir.NO_VALUE {
		return {}, false
	}
	#partial switch _ in s.fb.values[value].variant {
	case ir.Const_Undefined:
		return {.Undefined}, true
	case ir.Const_Null:
		return {.Null}, value_type(s, value) == ir.TAGGED
	}
	return {.Undefined}, value_type(s, value) == ir.VOID
}

@(private)
is_nullish_constant :: proc(s: ^Func_State, value: ir.Value_ID) -> bool {
	_, nullish := nullish_tags(s, value)
	return nullish
}

// truthy_tagged tests a tagged value. A variable declared with members that are all nullish or
// references is true exactly when it is neither null nor undefined, which is one tag test and no
// call. Its declaration decides, since check narrows a read past calls that may write the variable
// again.
@(private)
truthy_tagged :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	operand: ast.Node_ID,
	span: source.Span,
) -> ir.Value_ID {
	if declared_nullish_or_reference(s, operand) {
		return negated(s, tag_test(s, value, {.Undefined, .Null}, span), span)
	}
	call := ir.Call_Runtime {
		export = .Value_To_Boolean,
		args   = {value},
	}
	return ir.emit(&s.fb, ir.BOOL, call, span)
}

@(private)
declared_nullish_or_reference :: proc(s: ^Func_State, operand: ast.Node_ID) -> bool {
	if operand == ast.NO_NODE {
		return false
	}
	_, is_ident := s.tree.nodes[operand].variant.(ast.Ident)
	ref := s.typed.node_symbols[operand]
	if !is_ident || ref.symbol == bind.NO_SYMBOL || ref.file == program.LIB {
		return false
	}
	facts := &s.low.facts[ref.file]
	declaration := s.low.prog.bound[ref.file].symbols[ref.symbol].declaration
	type := facts.typed.node_types[declaration]
	return type != check.ERROR && nullish_or_reference(facts.result.types, type)
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

// lower_as converts the way requirements 3.8 allows: a widening boxes or changes nothing, and a
// narrowing of a tagged value, or of a reference that may be null, checks what it holds, failing
// with Type_Assertion. An `any` or an `unknown` never becomes a type that holds a function.
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
		return coerce(s, value, target, span, .Type_Assertion)
	}
	if target != ir.TAGGED {
		return unbox_checked(s, value, target, .Type_Assertion, span)
	}
	check_members(s, value, to, .Type_Assertion, span)
	return value
}

// check_members fails the program unless a tagged value holds a member of the union: the tag of a
// primitive or a function member, or an object of the layout of an object or an array member. An
// `any` member admits everything, and a literal member its whole kind.
@(private)
check_members :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	type: check.Type_ID,
	error: abi.Runtime_Error,
	span: source.Span,
) {
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
	fail_block(s, failed, error, span)
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

// any_to_function answers ANY or UNKNOWN where a flow of given into wanted brings a value of that
// type to a position that may hold a function, and ERROR where it does not. It walks the positions
// the way check's list_widenings does: a union member by member, the parameters of two functions
// the other way round and their results, unless wanted throws its result away, the fields of two
// objects and the elements of two arrays. A pair walked once ends the walk.
@(private)
any_to_function :: proc(types: []check.Type, given, wanted: check.Type_ID) -> check.Type_ID {
	seen := make([dynamic][2]check.Type_ID, 0, 8, context.temp_allocator)
	return any_to_function_in(types, given, wanted, &seen)
}

@(private)
any_to_function_in :: proc(
	types: []check.Type,
	given, wanted: check.Type_ID,
	seen: ^[dynamic][2]check.Type_ID,
) -> check.Type_ID {
	if given == wanted || given == check.ERROR || wanted == check.ERROR {
		return check.ERROR
	}
	if given == check.ANY || given == check.UNKNOWN {
		return given if holds_function(types, wanted) else check.ERROR
	}
	pair := [2]check.Type_ID{given, wanted}
	if slice.contains(seen[:], pair) {
		return check.ERROR
	}
	append(seen, pair)

	if members, is_union := types[given].(check.Union); is_union {
		for member in members.members {
			if found := any_to_function_in(types, member, wanted, seen); found != check.ERROR {
				return found
			}
		}
		return check.ERROR
	}
	if members, is_union := types[wanted].(check.Union); is_union {
		for member in members.members {
			if found := any_to_function_in(types, given, member, seen); found != check.ERROR {
				return found
			}
		}
		return check.ERROR
	}
	#partial switch from in types[given] {
	case check.Function:
		to := types[wanted].(check.Function) or_break
		for i in 0 ..< min(len(from.params), len(to.params)) {
			found := any_to_function_in(types, to.params[i].type, from.params[i].type, seen)
			if found != check.ERROR {
				return found
			}
		}
		if to.result != check.VOID {
			return any_to_function_in(types, from.result, to.result, seen)
		}
	case check.Object:
		to := types[wanted].(check.Object) or_break
		for field in from.fields {
			other, found := find_field(to, field.name)
			if !found {
				continue
			}
			nested := any_to_function_in(types, field.type, other.type, seen)
			if nested != check.ERROR {
				return nested
			}
		}
	case check.Array:
		to := types[wanted].(check.Array) or_break
		return any_to_function_in(types, from.element, to.element, seen)
	}
	return check.ERROR
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
		// and the box is an object either way. A reference and one that may be null, which widening
		// put in one slot, are read and written as the latter.
		slot := s.low.builder.layouts[group.layout].fields[group.field].kind
		switch {
		case slot == .Tagged:
			group.mixed = true
			group.type = ir.TAGGED
		case ir.fits(group.type, member.type):
			group.type = member.type
		case ir.fits(member.type, group.type):
		case group.type.kind != .Ref || member.type.kind != .Ref:
			later(s, span, "a field whose representation differs across the members of a union")
			return nil, false
		case:
			group.mixed = true
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
