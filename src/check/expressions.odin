package check

import "core:strings"

import "../ast"
import "../bind"
import "../source"

// check_expression is the type of one expression. It is the exhaustive switch over the shapes of
// ast: a statement or a piece of type syntax reaching it has no value and answers with the error
// type, which is what `for (i = 0; ...)` needs, since a `for` header holds either.
//
// expected is the type the expression is going into, which requirements 5 calls contextual typing:
// it gives an arrow parameter its type, keeps a literal field from widening, and tells an empty
// array literal what it holds. Only the shapes that can use it read it, and the error type means
// there is no context, which is also what a context that failed should say.
//
// Every rule that reports gives its node the error type. The error type is assignable in both
// directions, so one mistake stays one message however far the value travels.
@(private)
check_expression :: proc(c: ^Checker, id: ast.Node_ID, expected := ERROR) -> Type_ID {
	if id == ast.NO_NODE {
		return ERROR
	}

	switch v in c.at.tree.nodes[id].variant {
	case ast.Number_Literal:
		return set_type(c, id, literal_type(&c.table, v.value))
	case ast.String_Literal:
		return set_type(c, id, literal_type(&c.table, v.value))
	case ast.Bool_Literal:
		return set_type(c, id, literal_type(&c.table, v.value))
	case ast.Null_Literal:
		return set_type(c, id, NULL)
	case ast.Ident:
		_, narrowed := check_ident(c, id, v)
		// This is where a name is read. check_ident also answers for the target of a plain
		// `s = "a"`, which is a write and asks nothing about what the variable held before.
		check_assigned(c, id)
		return set_type(c, id, narrowed)
	case ast.Template:
		for expression in v.expressions {
			check_expression(c, expression)
		}
		return set_type(c, id, STRING)
	case ast.Unary:
		return set_type(c, id, check_unary(c, v))
	case ast.Update:
		return set_type(c, id, check_update(c, v))
	case ast.Binary:
		return set_type(c, id, check_binary(c, id, v))
	case ast.Assign:
		return set_type(c, id, check_assign(c, v))
	case ast.Conditional:
		check_expression(c, v.condition)
		then_value := check_expression(c, v.then_value, expected)
		else_value := check_expression(c, v.else_value, expected)
		return set_type(c, id, union_of(c, then_value, else_value))
	case ast.Call:
		return set_type(c, id, check_call(c, id, v))
	case ast.Arrow:
		return set_type(c, id, check_arrow(c, v, expected))
	case ast.Non_Null:
		return set_type(c, id, check_non_null(c, id, v))
	case ast.As:
		return set_type(c, id, check_as(c, v))

	case ast.Array_Literal:
		return set_type(c, id, check_array_literal(c, id, v, expected))
	case ast.Object_Literal:
		return set_type(c, id, check_object_literal(c, id, v, expected))
	case ast.Member:
		_, narrowed := check_member(c, id, v)
		return set_type(c, id, narrowed)
	case ast.Index:
		_, narrowed := check_index(c, id, v)
		return set_type(c, id, narrowed)

	// Not expressions: a statement, a piece of type syntax, or a part of a declaration. parse has
	// already reported a Bad node, so it says nothing here either.
	case ast.Bad,
	     ast.Module,
	     ast.Var_Decl,
	     ast.Declarator,
	     ast.Function_Decl,
	     ast.Param,
	     ast.Type_Param,
	     ast.Interface_Decl,
	     ast.Type_Alias_Decl,
	     ast.Import_Named,
	     ast.Import_Namespace,
	     ast.Export_Named,
	     ast.Specifier,
	     ast.Property,
	     ast.Block,
	     ast.Expr_Stmt,
	     ast.If,
	     ast.Switch,
	     ast.Case,
	     ast.For,
	     ast.For_Of,
	     ast.While,
	     ast.Do_While,
	     ast.Break,
	     ast.Continue,
	     ast.Return,
	     ast.Empty,
	     ast.Keyword_Type,
	     ast.Literal_Type,
	     ast.Type_Ref,
	     ast.Array_Type,
	     ast.Union_Type,
	     ast.Function_Type,
	     ast.Object_Type,
	     ast.Property_Signature:
		return ERROR
	}
	return ERROR
}

// Names.

// check_ident is the type of a use of a name. It answers twice, as the other two reads of a place
// do: with the type the name was declared with, and with the type it holds here, which
// narrow_reference works out from the flow graph.
//
// `undefined` is a name in the grammar rather than a literal, and no file declares it, so check
// answers for it itself. A name another module declares goes to imported_name, which follows the
// import to the declaration behind it.
@(private)
check_ident :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Ident,
) -> (
	declared, narrowed: Type_ID,
) {
	ref := resolve_name(c, id, node.name, .Value)
	if ref.symbol == bind.NO_SYMBOL {
		if node.name == "undefined" {
			return UNDEFINED, UNDEFINED
		}
		report_unknown_name(c, node.name, span_of(c, id))
		return ERROR, ERROR
	}
	if bind.is_alias(c.program.bound[ref.file].symbols[ref.symbol].kind) {
		return imported_name(c, id, node.name, ref)
	}
	set_symbol(c, id, ref)
	declared = type_of_symbol(c, ref)
	return declared, narrow_reference(c, id, declared)
}

// check_assigned reports a read of a `let` that no path leading here has given a value. It is the
// rule tsc writes TS2454, and it is flow analysis rather than a look at the declaration: a variable
// assigned in both branches of an `if` is fine, one assigned in a single branch is not.
//
// Three shapes tsc accepts are reported all the same. tsc assumes an outer variable is assigned
// whenever the read stands in another function, and it can, because Node throws when that turns out
// false; tsnc has no such check at run time, so the variable would hold garbage. The hint says what
// to write instead.
@(private)
check_assigned :: proc(c: ^Checker, id: ast.Node_ID) {
	// bind's own answer, not check's: it names a symbol for a name this file declares, and the one
	// an import declares is an alias rather than a `let`, so starts_empty stops there. That is what
	// keeps an exported variable, reported once at its own declaration, to one message.
	symbol := c.at.bound.node_symbols[id]
	if symbol == bind.NO_SYMBOL {
		return
	}
	ref := Symbol_Ref {
		file   = c.at.file,
		symbol = symbol,
	}
	if !starts_empty(c, ref) || !reaches_start(c, c.at.bound.node_flow[id], id) {
		return
	}
	report(c, .Used_Before_Assigned, span_of(c, id), c.at.bound.symbols[symbol].name.text)
}

// starts_empty reports whether a binding holds no value until something writes one: a `let` written
// with a type, with no initializer, whose type does not admit `undefined`. A variable that admits it
// simply starts as `undefined`, and a `for...of` variable has no type of its own to write.
@(private)
starts_empty :: proc(c: ^Checker, ref: Symbol_Ref) -> bool {
	symbol := c.program.bound[ref.file].symbols[ref.symbol]
	if symbol.kind != .Let || symbol.declaration == ast.NO_NODE {
		return false
	}
	declaration := c.program.trees[ref.file].nodes[symbol.declaration].variant
	node, is_declarator := declaration.(ast.Declarator)
	if !is_declarator || node.type == ast.NO_NODE || node.init != ast.NO_NODE {
		return false
	}
	return !fits(c, UNDEFINED, type_of_symbol(c, ref))
}

// Operators.

@(private)
check_unary :: proc(c: ^Checker, node: ast.Unary) -> Type_ID {
	operand := check_expression(c, node.operand)
	switch node.op {
	case .Not:
		return BOOLEAN // every value is either truthy or falsy, so `!` takes anything
	case .Typeof:
		return typeof_type(c)
	case .Minus, .Plus, .Bit_Not:
		// A minus written in front of a number is part of the number: tsc reads `-1` as the literal
		// type `-1`, so `const step: -1 = -1` holds. literal_type folds `-0` back into `0`.
		if literal, is_literal := c.table.types[operand].(Literal);
		   is_literal && node.op == .Minus {
			if value, is_number := literal.value.(f64); is_number {
				return literal_type(&c.table, -value)
			}
		}
		if !based_on(c, operand, NUMBER) {
			report(
				c,
				.Operand_Not_Number,
				span_of(c, node.operand),
				UNARY_TEXTS[node.op],
				text_of(c, operand),
			)
			return ERROR
		}
		return NUMBER
	}
	return ERROR
}

// check_update types `x++` and `--x`. They are assignments, so they need a number and a binding
// that is allowed to take another value.
@(private)
check_update :: proc(c: ^Checker, node: ast.Update) -> Type_ID {
	operand := check_expression(c, node.operand)
	_ = check_mutable(c, node.operand)
	if !based_on(c, operand, NUMBER) {
		report(
			c,
			.Operand_Not_Number,
			span_of(c, node.operand),
			UPDATE_TEXTS[node.op],
			text_of(c, operand),
		)
		return ERROR
	}
	return NUMBER
}

@(private)
check_binary :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Binary) -> Type_ID {
	left := check_expression(c, node.left)
	right := check_expression(c, node.right)

	switch node.op {
	// A logical operator keeps a part of its left side and joins it to the right: `a && b` is `a`
	// exactly where `a` is falsy, and `a || b` is `a` exactly where `a` is truthy.
	case .And:
		return union_of(c, part_of(&c.table, left, .Falsy), right)
	case .Or:
		return union_of(c, part_of(&c.table, left, .Truthy), right)
	case .Coalesce:
		return union_of(c, part_of(&c.table, left, .Not_Nullish), right)

	case .Add:
		return add_result(c, span_of(c, id), left, right)
	case .Subtract,
	     .Multiply,
	     .Divide,
	     .Remainder,
	     .Power,
	     .Shift_Left,
	     .Shift_Right,
	     .Shift_Right_Unsigned,
	     .Bit_And,
	     .Bit_Or,
	     .Bit_Xor:
		spans := [2]source.Span{span_of(c, node.left), span_of(c, node.right)}
		return arithmetic_result(c, BINARY_TEXTS[node.op], spans, left, right)
	case .Less, .Less_Equal, .Greater, .Greater_Equal:
		return order_result(c, span_of(c, id), left, right)
	case .Strict_Equal, .Strict_Not_Equal:
		// Requirements 3.7 asks nothing of `===` itself, but two types with no value in common make
		// a comparison that is a mistake rather than a test, and tsc reports it as well.
		if !comparable(c, left, right) {
			report_types(c, .No_Overlap, span_of(c, id), left, right)
		}
		return BOOLEAN
	case .Equal, .Not_Equal:
		return equality_result(c, span_of(c, id), left, right)
	}
	return ERROR
}

// add_result is the type `+` gives. It is the one operator that works on two kinds of value: it
// adds two numbers, or joins a string to anything.
@(private)
add_result :: proc(c: ^Checker, span: source.Span, left, right: Type_ID) -> Type_ID {
	if left == ERROR || right == ERROR {
		return ERROR
	}
	if left == ANY || right == ANY {
		return ANY
	}
	if based_on(c, left, STRING) || based_on(c, right, STRING) {
		return STRING
	}
	if based_on(c, left, NUMBER) && based_on(c, right, NUMBER) {
		return NUMBER
	}
	report_types(c, .Addition_Operands, span, left, right)
	return ERROR
}

// arithmetic_result is the type every other arithmetic and bitwise operator gives. A bitwise one
// answers `number` as well: requirements 3.1 puts the conversion to int32 in the semantics, not in
// the type. spans holds where each operand stands, so the message points at the one that is wrong.
@(private)
arithmetic_result :: proc(
	c: ^Checker,
	text: string,
	spans: [2]source.Span,
	left, right: Type_ID,
) -> Type_ID {
	operands := [2]Type_ID{left, right}
	ok := true
	for operand, i in operands {
		if !based_on(c, operand, NUMBER) {
			report(c, .Operand_Not_Number, spans[i], text, text_of(c, operand))
			ok = false
		}
	}
	return NUMBER if ok else ERROR
}

// order_result is the type `<`, `<=`, `>` and `>=` give: two numbers or two strings compare, and
// nothing else does.
@(private)
order_result :: proc(c: ^Checker, span: source.Span, left, right: Type_ID) -> Type_ID {
	if left == ERROR || right == ERROR || left == ANY || right == ANY {
		return BOOLEAN
	}
	numbers := based_on(c, left, NUMBER) && based_on(c, right, NUMBER)
	strings := based_on(c, left, STRING) && based_on(c, right, STRING)
	if numbers || strings {
		return BOOLEAN
	}
	report_types(c, .Comparison_Operands, span, left, right)
	return ERROR
}

// equality_result is the rule of requirements 3.7: `==` and `!=` are allowed only where both sides
// already have one type, and there they mean `===`. Anywhere else one side would be converted, and
// requirements 2.2 lists a converting comparison among the things tsnc never supports.
@(private)
equality_result :: proc(c: ^Checker, span: source.Span, left, right: Type_ID) -> Type_ID {
	if left == ERROR || right == ERROR {
		return BOOLEAN
	}
	if widen(&c.table, left) == widen(&c.table, right) {
		return BOOLEAN
	}
	report_types(c, .Loose_Equality, span, left, right)
	return ERROR
}

// typeof_type is what `typeof x` gives: the answers the operator can produce, as TypeScript
// declares them. v1 has neither `symbol` nor `bigint`, so those two answers are left out.
@(private)
typeof_type :: proc(c: ^Checker) -> Type_ID {
	answers: [len(TYPEOF_ANSWERS)]Type_ID
	for text, i in TYPEOF_ANSWERS {
		answers[i] = literal_type(&c.table, text)
	}
	return union_type(&c.table, answers[:])
}

@(private, rodata)
TYPEOF_ANSWERS := [?]string{"boolean", "function", "number", "object", "string", "undefined"}

// Objects and arrays.

// check_object_literal is the type of `{ a: 1, b: "x" }`. A literal written where an object type is
// expected is checked against that type and takes it as its own: a field the type does not declare
// is a mistake, a field the literal leaves out is one unless the type wrote it `x?: T`, and T5.7
// puts `undefined` in the slot of the one left out. TypeScript calls a literal read this way fresh,
// and it is what keeps the exact-type rule of requirements 3.3 from rejecting
// `const p: Opts = { x: 1 }` while two named types still need the same set of fields.
//
// With no context the literal makes its own type and widens every field, because a field can take
// another value of its kind later.
@(private)
check_object_literal :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Object_Literal,
	expected: Type_ID,
) -> Type_ID {
	names := make([dynamic]string, 0, len(node.properties), context.temp_allocator)
	tags := make([dynamic]Type_ID, 0, len(node.properties), context.temp_allocator)
	for property_id in node.properties {
		property := c.at.tree.nodes[property_id].variant.(ast.Property)
		append(&names, property.name.text)
		append(&tags, tag_type(c, property.value))
	}
	target_id, target, has_target := expected_object(c, expected, names[:], tags[:])

	fields := make([dynamic]Field, 0, len(node.properties), context.temp_allocator)
	for property_id in node.properties {
		property := c.at.tree.nodes[property_id].variant.(ast.Property)
		if !check_member_name(c, property.name) {
			// The value is still typed, so a mistake inside it is found, but the field is left out:
			// the object does not have it, and the exact-type rule must not report it a second time.
			set_type(c, property_id, check_expression(c, property.value))
			continue
		}
		declared, known := ERROR, false
		if has_target {
			field, found := find_field(target.fields, property.name.text)
			declared, known = field_read_type(c, field), found
			if !found {
				span := property.name.span
				report(c, .Field_Not_Found, span, property.name.text, text_of(c, target_id))
			}
		}

		value := check_expression(c, property.value, declared)
		set_type(c, property_id, value)

		as_declared := known && fits(c, value, declared)
		if known && !as_declared {
			report_assign_failure(c, span_of(c, property.value), value, declared)
		}
		kept := declared if as_declared else widen(&c.table, value)
		add_field(c, &fields, {name = property.name.text, type = kept}, property.name)
	}

	if !has_target {
		sort_fields(fields[:])
		return plain_object_type(&c.table, fields[:])
	}

	for field in target.fields {
		if field.optional {
			continue
		}
		if _, found := find_field(fields[:], field.name); !found {
			report(c, .Missing_Field, span_of(c, id), field.name, text_of(c, target_id))
		}
	}
	return target_id
}

// tag_type is what a property value is worth before anything is typed, where it is written out as
// one: a discriminated union is picked by these, so every shape that can tag one answers here. A
// tag given through a name, as `{ kind: k }`, is not one of them and is not looked at.
//
// `undefined` is a name in the grammar rather than a literal, and it is that name only where no
// file declares it, which is how check_ident tells it too.
@(private)
tag_type :: proc(c: ^Checker, id: ast.Node_ID) -> Type_ID {
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.String_Literal:
		return literal_type(&c.table, v.value)
	case ast.Number_Literal:
		return literal_type(&c.table, v.value)
	case ast.Bool_Literal:
		return literal_type(&c.table, v.value)
	case ast.Null_Literal:
		return NULL
	case ast.Unary:
		// A minus written in front of a number is part of the number, as check_unary reads it.
		number, is_number := c.at.tree.nodes[v.operand].variant.(ast.Number_Literal)
		if v.op == .Minus && is_number {
			return literal_type(&c.table, -number.value)
		}
	case ast.Ident:
		if v.name == "undefined" && resolve_name(c, id, v.name, .Value).symbol == bind.NO_SYMBOL {
			return UNDEFINED
		}
	}
	return ERROR
}

// check_array_literal is the type of `[1, 2, 3]`. Requirements 5 takes an array's element type from
// its literal, so with no context it is the canonical union of the widened element types. An empty
// literal has nothing to take it from and says so rather than guessing, since guessing would push
// the mistake into the first `push`.
@(private)
check_array_literal :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Array_Literal,
	expected: Type_ID,
) -> Type_ID {
	wanted := context_of(c, expected, .Array)
	if target, is_array := c.table.types[wanted].(Array); is_array {
		for element in node.elements {
			value := check_expression(c, element, target.element)
			if !fits(c, value, target.element) {
				report_assign_failure(c, span_of(c, element), value, target.element)
			}
		}
		return wanted
	}

	elements := make([dynamic]Type_ID, 0, len(node.elements), context.temp_allocator)
	for element in node.elements {
		append(&elements, widen(&c.table, check_expression(c, element)))
	}
	if len(elements) == 0 {
		report(c, .Empty_Array_Literal, span_of(c, id))
		return ERROR
	}
	return array_type(&c.table, union_type(&c.table, elements[:]))
}

// check_member is the type of `x.name`. The fields come from the apparent type: an object's own, and
// for a string, a number or an array the members the lib file declares for it. `m.name`, where m is
// an `import * as m`, is no field read at all: it names a declaration of the other module.
@(private)
check_member :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Member,
) -> (
	declared, narrowed: Type_ID,
) {
	if !check_member_name(c, node.name) {
		// The prototype rule is asked before the object is typed, so that `(x as any).__proto__` is
		// reported too: a value the rules gave up on is still a value with no prototype.
		check_expression(c, node.object)
		return ERROR, ERROR
	}
	if ref, is_namespace := namespace_of(c, node.object); is_namespace {
		return namespace_member(c, id, node, ref)
	}

	object := check_expression(c, node.object)
	if object == ERROR || object == ANY {
		return object, object
	}

	field, found := field_of(c, object, node.name.text)
	if !found {
		report(c, .Field_Not_Found, node.name.span, node.name.text, text_of(c, object))
		return ERROR, ERROR
	}
	declared = field_read_type(c, field)
	return declared, narrow_reference(c, id, declared)
}

// check_index is the type of `x[i]`. The lib file has no index signatures, so the checker knows by
// itself that an array gives its element and a string gives a string. Reading out of range is a
// runtime check of requirements 3.8 and not a `T | undefined`, so the type is the element itself.
@(private)
check_index :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Index,
) -> (
	declared, narrowed: Type_ID,
) {
	object := check_expression(c, node.object)
	index := check_expression(c, node.index)
	if !based_on(c, index, NUMBER) {
		report_types(c, .Type_Mismatch, span_of(c, node.index), index, NUMBER)
	}
	if object == ERROR || object == ANY {
		return object, object
	}

	if array, is_array := c.table.types[object].(Array); is_array {
		return array.element, narrow_reference(c, id, array.element)
	}
	if based_on(c, object, STRING) {
		return STRING, narrow_reference(c, id, STRING)
	}
	report(c, .Not_Indexable, span_of(c, node.object), text_of(c, object))
	return ERROR, ERROR
}

// Assertions.

// check_non_null is the type of `x!`. Requirements 3.8 makes it a runtime check and lower emits
// one, so it has to be a check worth making: a value that can never be null or undefined is
// reported rather than quietly accepted, which is where tsnc is stricter than tsc.
@(private)
check_non_null :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Non_Null) -> Type_ID {
	value := check_expression(c, node.expr)
	if value == ERROR || value == ANY {
		return value
	}
	if part_of(&c.table, value, .Nullish) == NEVER {
		report(c, .Needless_Non_Null, span_of(c, id), text_of(c, value))
		return value
	}
	return part_of(&c.table, value, .Not_Nullish)
}

// check_as is the type of `x as T`. Requirements 3.8 allows two conversions and no others: widening
// a value to a type that covers it, and narrowing a union to a part of it, which lower turns into a
// tag check. Neither `any` nor `unknown` may be the target at all, and that one rule is what makes
// `as any` and `as unknown as T` impossible, rather than a rule that looks for the pair.
@(private)
check_as :: proc(c: ^Checker, node: ast.As) -> Type_ID {
	value := check_expression(c, node.expr)
	target := resolve_type(c, node.type)

	if target == ANY || target == UNKNOWN {
		report(c, .Unsafe_Assertion, span_of(c, node.type), text_of(c, target))
		return ERROR
	}
	// One of the two conversions has to be the whole of it: `as` may widen a value to a type that
	// covers it, or narrow a union to a part of it, and nothing in between. That is narrower than
	// comparable, which lets two unions through where they merely share a member.
	if !fits(c, value, target) && !fits(c, target, value) {
		report_types(c, .Unrelated_Assertion, span_of(c, node.expr), value, target)
	}
	return target
}

// Assignment.

// check_target types the place an assignment writes to, and answers twice: with the type the place
// holds here, which a compound assignment computes from, and with the type it was declared with,
// which the new value has to fit. The two have to be told apart, or a narrowing would forbid the
// write that ends it: inside `if (typeof x === "number")` every read of x is a number, while
// `x = "a"` is still a legal write to a `string | number`.
@(private)
check_target :: proc(c: ^Checker, id: ast.Node_ID) -> (narrowed, declared: Type_ID) {
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Ident:
		declared, narrowed = check_ident(c, id, v)
	case ast.Member:
		declared, narrowed = check_member(c, id, v)
	case ast.Index:
		declared, narrowed = check_index(c, id, v)
	case:
		// parse has already rejected a target that is no place to write to at all.
		narrowed = check_expression(c, id)
		return narrowed, narrowed
	}
	set_type(c, id, narrowed)
	return narrowed, declared
}

@(private)
check_assign :: proc(c: ^Checker, node: ast.Assign) -> Type_ID {
	narrowed, declared := check_target(c, node.target)
	if node.op != .Assign {
		// `x += y` means `x = x + y`, so the target is read as well; check_target went through
		// check_ident, which is not where a read is counted.
		check_assigned(c, node.target)
	}
	writable := check_mutable(c, node.target)
	value := check_expression(c, node.value, declared if node.op == .Assign else ERROR)

	result := value
	if node.op != .Assign {
		result = compound_result(c, node, narrowed, value)
	}
	// A binding that cannot take another value has been reported already. Measuring the value
	// against the one type that binding will ever have would only say the same thing twice.
	if writable && !fits(c, result, declared) {
		report_assign_failure(c, span_of(c, node.value), result, declared)
	}
	return result
}

// compound_result is the value `x += y` and its kin work out before the assignment: they mean
// `x = x <op> y`, so each one answers the way its operator does.
@(private)
compound_result :: proc(c: ^Checker, node: ast.Assign, target, value: Type_ID) -> Type_ID {
	target_span, value_span := span_of(c, node.target), span_of(c, node.value)

	switch node.op {
	case .Add:
		return add_result(c, value_span, target, value)
	case .And:
		return union_of(c, part_of(&c.table, target, .Falsy), value)
	case .Or:
		return union_of(c, part_of(&c.table, target, .Truthy), value)
	case .Coalesce:
		return union_of(c, part_of(&c.table, target, .Not_Nullish), value)
	case .Assign:
		return value
	case .Subtract,
	     .Multiply,
	     .Divide,
	     .Remainder,
	     .Power,
	     .Shift_Left,
	     .Shift_Right,
	     .Shift_Right_Unsigned,
	     .Bit_And,
	     .Bit_Or,
	     .Bit_Xor:
		spans := [2]source.Span{target_span, value_span}
		return arithmetic_result(c, ASSIGN_TEXTS[node.op], spans, target, value)
	}
	return ERROR
}

// check_mutable reports a write to a place that cannot take another value, and answers whether the
// write may go ahead. parse has already rejected a target that is no place to write to at all, and
// check_assign has typed the target, so the type of the object a field belongs to is recorded.
//
// An element of an array is always writable: requirements 3.8 makes `arr[i] = x` grow the array at
// its end and fail past it, which is a runtime check and not a type rule.
@(private)
check_mutable :: proc(c: ^Checker, target: ast.Node_ID) -> (writable: bool) {
	#partial switch v in c.at.tree.nodes[target].variant {
	case ast.Ident:
		ref := resolve_name(c, target, v.name, .Value)
		if ref.symbol == bind.NO_SYMBOL {
			return true
		}
		kind := c.program.bound[ref.file].symbols[ref.symbol].kind
		if kind == .Function {
			report(c, .Assign_To_Function, span_of(c, target), v.name)
			return false
		}
		// An imported name is a binding of the other module seen from here, and ESM makes it
		// read-only whichever keyword declared it there, so it answers as a `const` does.
		if kind == .Const || bind.is_alias(kind) {
			report(c, .Assign_To_Const, span_of(c, target), v.name)
			return false
		}
	case ast.Member:
		if _, is_namespace := namespace_of(c, v.object); is_namespace {
			// `m.x` through an `import * as m` names the other module's binding, which is the same
			// binding an imported name is, so it answers the same way.
			report(c, .Assign_To_Const, v.name.span, v.name.text)
			return false
		}
		if c.at.node_types == nil {
			return true // a generic lib declaration being instantiated records no facts
		}
		field, found := field_of(c, c.at.node_types[v.object], v.name.text)
		if found && field.readonly {
			report(c, .Assign_To_Readonly, v.name.span, v.name.text)
			return false
		}
	}
	return true
}

// Calls and arrows.

// check_call is the type a call gives back. A member declared more than once offers several
// signatures, and the call takes the first whose arity fits, which is what src/lib/lib.d.ts says its
// two `reduce` declarations rely on. check_signature_call then checks the arguments against it.
@(private)
check_call :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Call) -> Type_ID {
	callee := check_expression(c, node.callee)
	if callee == ERROR || callee == ANY {
		check_loose_arguments(c, node.args)
		return callee
	}

	signatures := make([dynamic]Type_ID, 0, 2, context.temp_allocator)
	append_signatures(c, &signatures, callee)
	if len(signatures) == 0 {
		check_loose_arguments(c, node.args)
		report(c, .Not_Callable, span_of(c, node.callee), text_of(c, callee))
		return ERROR
	}

	for signature in signatures {
		if arity_fits(c.table.types[signature].(Function), len(node.args)) {
			return check_signature_call(c, id, node, signature)
		}
	}

	check_loose_arguments(c, node.args)
	function := c.table.types[signatures[0]].(Function)
	report(
		c,
		.Argument_Count,
		span_of(c, id),
		arity_text(c, function),
		count_text(c, len(node.args)),
	)
	return function.result
}

// check_loose_arguments types the arguments of a call with no signature to measure them against, so
// that a mistake inside one is still found.
@(private)
check_loose_arguments :: proc(c: ^Checker, args: []ast.Node_ID) {
	for argument in args {
		check_expression(c, argument)
	}
}

@(private)
arity_fits :: proc(function: Function, count: int) -> bool {
	if count < function.required {
		return false
	}
	return function.variadic || count <= len(function.params)
}

// parameter_at is the type the argument in that position is checked against. An argument that lands
// on a rest parameter is checked against the element type of `...xs: T[]`, which is what makes
// `console.log(1, "a")` and `Math.max(1, 2, 3)` work.
@(private)
parameter_at :: proc(c: ^Checker, function: Function, index: int) -> Type_ID {
	last := len(function.params) - 1
	if function.variadic && index >= last {
		element, is_array := c.table.types[function.params[last].type].(Array)
		return element.element if is_array else ERROR
	}
	if index >= len(function.params) {
		return ERROR
	}

	declared := function.params[index].type
	if index < function.required {
		return declared
	}
	// The argument may be left out where the parameter is optional, so passing `undefined` there
	// is the same thing said out loud.
	return union_of(c, declared, UNDEFINED)
}

// check_arrow types an arrow, which is a value with a signature of its own. Requirements 5 gives a
// parameter with no annotation its type from the signature the arrow is going into, so
// `arr.map(x => x * 2)` needs no `x: number`.
//
// The result is taken from the context too, where the context asks for one that holds no type
// variable and the body delivers it. A type variable is exactly what a call reads back out of the
// body, so `map<U>` and `reduce<U>` keep inferring; everything else reads better with the context,
// because `r => ({ kind: "circle", r: r })` has to keep `kind` a literal.
//
// declaration is the node this arrow is the initializer of, when there is one. The signature lands
// there before the body goes in, so that a call to the name inside the body finds it.
@(private)
check_arrow :: proc(
	c: ^Checker,
	node: ast.Arrow,
	expected := ERROR,
	declaration := ast.NO_NODE,
) -> Type_ID {
	contextual: Maybe(Function)
	given := context_of(c, expected, .Function)
	if signature, is_function := c.table.types[given].(Function); is_function {
		contextual = signature
	}
	params, required, variadic := resolve_params(c, node.params, contextual)

	if node.return_type != ast.NO_NODE {
		result := resolve_type(c, node.return_type)
		type := function_type(&c.table, params, result, required, variadic)
		if declaration != ast.NO_NODE {
			set_type(c, declaration, type)
		}
		check_body(c, node.body, result, nil)
		check_result_reached(c, node.body, node.return_type, result)
		return type
	}

	wanted := contextual_result(c, contextual)
	returns := make([dynamic]Type_ID, 0, 4, context.temp_allocator)
	check_body(c, node.body, wanted, &returns)
	if wanted != ERROR && returns_fit(c, node.body, returns[:], wanted) {
		return function_type(&c.table, params, wanted, required, variadic)
	}

	result := inferred_result(c, node.body, returns[:])
	return function_type(&c.table, params, result, required, variadic)
}

// contextual_result is the result an arrow's body may be typed against: the one the context asks
// for, where the context is a signature whose result is known and holds no type variable anywhere
// inside it.
@(private)
contextual_result :: proc(c: ^Checker, contextual: Maybe(Function)) -> Type_ID {
	signature, has_signature := contextual.?
	if !has_signature || signature.result == ERROR || has_type_var(c, signature.result) {
		return ERROR
	}
	return signature.result
}

// returns_fit reports whether every path out of a body gives a value the contextual result takes: a
// bare `return`, which is VOID here and `undefined` in the result, and running off the end as well.
// A body with no `return` at all has nothing to take the context on.
@(private)
returns_fit :: proc(c: ^Checker, body: ast.Node_ID, returns: []Type_ID, result: Type_ID) -> bool {
	if len(returns) == 0 {
		return false
	}
	for type in returns {
		if !fits(c, UNDEFINED if type == VOID else type, result) {
			return false
		}
	}
	return !falls_through(c, body) || fits(c, UNDEFINED, result)
}

// has_type_var reports whether a type holds a type variable anywhere inside it. A named object is
// settled by its arguments: `Array<U>` holds `U` there, and a field of it holds nothing the
// arguments do not, while asking the fields would not end for an interface that names itself.
@(private)
has_type_var :: proc(c: ^Checker, id: Type_ID) -> bool {
	switch v in c.table.types[id] {
	case Basic_Kind, Literal:
		return false
	case Type_Var:
		return true
	case Array:
		return has_type_var(c, v.element)
	case Union:
		for member in v.members {
			if has_type_var(c, member) {
				return true
			}
		}
	case Overload:
		for signature in v.signatures {
			if has_type_var(c, signature) {
				return true
			}
		}
	case Function:
		for param in v.params {
			if has_type_var(c, param.type) {
				return true
			}
		}
		return has_type_var(c, v.result)
	case Object:
		for arg in v.args {
			if has_type_var(c, arg) {
				return true
			}
		}
		if v.decl != NO_DECL {
			return false
		}
		for field in v.fields {
			if has_type_var(c, field.type) {
				return true
			}
		}
	}
	return false
}

// Shape is what an expression needs of the type it is going into: an array literal needs an array,
// an arrow needs a signature.
@(private)
Shape :: enum u8 {
	Array,
	Function,
}

// context_of is the part of an expected type an expression can read. An optional parameter and a
// variable written `T | undefined` are unions, and a literal going into one has to look through it
// the way an object literal already does: the answer is the type itself where it has the shape, the
// one member of a union that has it, and the error type where none or several do.
@(private)
context_of :: proc(c: ^Checker, expected: Type_ID, shape: Shape) -> Type_ID {
	if has_shape(c, expected, shape) {
		return expected
	}
	members, is_union := c.table.types[expected].(Union)
	if !is_union {
		return ERROR
	}

	found := ERROR
	for member in members.members {
		if !has_shape(c, member, shape) {
			continue
		}
		if found != ERROR {
			return ERROR // two members of the shape leave a choice nothing here can make
		}
		found = member
	}
	return found
}

@(private)
has_shape :: proc(c: ^Checker, id: Type_ID, shape: Shape) -> bool {
	switch shape {
	case .Array:
		_, is_array := c.table.types[id].(Array)
		return is_array
	case .Function:
		_, is_function := c.table.types[id].(Function)
		return is_function
	}
	return false
}

// Reading a type.

// based_on reports whether every value of id is a value of base: base itself, a literal of it, or a
// union of those. The error type and `any` pass, because one has been reported already and the
// other is the type that gives up on checking.
@(private)
based_on :: proc(c: ^Checker, id: Type_ID, base: Type_ID) -> bool {
	if id == ERROR || id == ANY {
		return true
	}
	switch v in c.table.types[id] {
	case Basic_Kind:
		return id == base
	case Literal:
		return literal_base(v.value) == base
	case Function, Object, Array, Type_Var, Overload:
		return false
	case Union:
		for member in v.members {
			if !based_on(c, member, base) {
				return false
			}
		}
		return true
	}
	return false
}

// arity_text is how a diagnostic names what a signature takes: `1 argument`, `1 to 3 arguments`,
// `at least 2 arguments`.
@(private)
arity_text :: proc(c: ^Checker, function: Function) -> string {
	b := strings.builder_make(c.allocator)
	if function.variadic {
		strings.write_string(&b, "at least ")
		strings.write_int(&b, function.required)
		write_arguments(&b, function.required)
		return strings.to_string(b)
	}

	strings.write_int(&b, function.required)
	if function.required != len(function.params) {
		strings.write_string(&b, " to ")
		strings.write_int(&b, len(function.params))
	}
	write_arguments(&b, len(function.params))
	return strings.to_string(b)
}

@(private)
count_text :: proc(c: ^Checker, count: int) -> string {
	b := strings.builder_make(c.allocator)
	strings.write_int(&b, count)
	write_arguments(&b, count)
	return strings.to_string(b)
}

@(private)
write_arguments :: proc(b: ^strings.Builder, count: int) {
	strings.write_string(b, " argument" if count == 1 else " arguments")
}

// Operator texts. They name the operator in a diagnostic, spelled as the source writes it.

@(private, rodata)
UNARY_TEXTS := [ast.Unary_Op]string {
	.Minus   = "-",
	.Plus    = "+",
	.Not     = "!",
	.Bit_Not = "~",
	.Typeof  = "typeof",
}

@(private, rodata)
UPDATE_TEXTS := [ast.Update_Op]string {
	.Pre_Increment  = "++",
	.Pre_Decrement  = "--",
	.Post_Increment = "++",
	.Post_Decrement = "--",
}

@(private, rodata)
BINARY_TEXTS := [ast.Binary_Op]string {
	.Add                  = "+",
	.Subtract             = "-",
	.Multiply             = "*",
	.Divide               = "/",
	.Remainder            = "%",
	.Power                = "**",
	.Shift_Left           = "<<",
	.Shift_Right          = ">>",
	.Shift_Right_Unsigned = ">>>",
	.Bit_And              = "&",
	.Bit_Or               = "|",
	.Bit_Xor              = "^",
	.Less                 = "<",
	.Less_Equal           = "<=",
	.Greater              = ">",
	.Greater_Equal        = ">=",
	.Equal                = "==",
	.Not_Equal            = "!=",
	.Strict_Equal         = "===",
	.Strict_Not_Equal     = "!==",
	.And                  = "&&",
	.Or                   = "||",
	.Coalesce             = "??",
}

@(private, rodata)
ASSIGN_TEXTS := [ast.Assign_Op]string {
	.Assign               = "=",
	.Add                  = "+=",
	.Subtract             = "-=",
	.Multiply             = "*=",
	.Divide               = "/=",
	.Remainder            = "%=",
	.Power                = "**=",
	.Shift_Left           = "<<=",
	.Shift_Right          = ">>=",
	.Shift_Right_Unsigned = ">>>=",
	.Bit_And              = "&=",
	.Bit_Or               = "|=",
	.Bit_Xor              = "^=",
	.And                  = "&&=",
	.Or                   = "||=",
	.Coalesce             = "??=",
}
