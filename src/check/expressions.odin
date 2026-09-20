package check

import "core:strings"

import "../ast"
import "../bind"
import "../source"

// check_expression is the type of one expression. It is the exhaustive switch over the shapes of
// ast: a statement or a piece of type syntax reaching it has no value and answers with the error
// type, which is what `for (i = 0; ...)` needs, since a `for` header holds either.
//
// Every rule that reports gives its node the error type. The error type is assignable in both
// directions, so one mistake stays one message however far the value travels.
@(private)
check_expression :: proc(c: ^Checker, id: ast.Node_ID) -> Type_ID {
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
		return set_type(c, id, check_ident(c, id, v))
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
		then_value := check_expression(c, v.then_value)
		else_value := check_expression(c, v.else_value)
		return set_type(c, id, union_of(c, then_value, else_value))
	case ast.Call:
		return set_type(c, id, check_call(c, id, v))
	case ast.Arrow:
		return set_type(c, id, check_arrow(c, v))
	case ast.Non_Null:
		// `x!` says the value is there. T3.4 decides when that is allowed and lower turns it into
		// the check of requirements 3.8; the type it leaves behind is already this.
		return set_type(c, id, part_of(&c.table, check_expression(c, v.expr), .Not_Nullish))
	case ast.As:
		// T3.4 owns the rules: which conversions are allowed, and that `as any` is not one.
		check_expression(c, v.expr)
		return set_type(c, id, resolve_type(c, v.type))

	// Objects and arrays are T3.3. Their parts are still typed, so a mistake inside one is found,
	// but the node itself has no type yet and says nothing about it.
	case ast.Array_Literal:
		for element in v.elements {
			check_expression(c, element)
		}
		return set_type(c, id, ERROR)
	case ast.Object_Literal:
		for property in v.properties {
			check_expression(c, c.at.tree.nodes[property].variant.(ast.Property).value)
		}
		return set_type(c, id, ERROR)
	case ast.Member:
		check_expression(c, v.object)
		return set_type(c, id, ERROR)
	case ast.Index:
		check_expression(c, v.object)
		check_expression(c, v.index)
		return set_type(c, id, ERROR)

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

// check_ident is the type of a use of a name. `undefined` is a name in the grammar rather than a
// literal, and no file declares it, so check answers for it itself.
@(private)
check_ident :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Ident) -> Type_ID {
	ref := resolve_name(c, id, node.name, .Value)
	if ref.symbol == bind.NO_SYMBOL {
		if node.name == "undefined" {
			return UNDEFINED
		}
		report(c, .Cannot_Find_Name, span_of(c, id), node.name)
		return ERROR
	}
	set_symbol(c, id, ref)
	return type_of_symbol(c, ref)
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
		// Requirements 3.7 asks nothing of `===`. tsc also reports two types that cannot overlap,
		// which needs the comparability relation, and that arrives with narrowing in T3.4.
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

// Assignment.

@(private)
check_assign :: proc(c: ^Checker, node: ast.Assign) -> Type_ID {
	target := check_expression(c, node.target)
	writable := check_mutable(c, node.target)
	value := check_expression(c, node.value)

	result := value
	if node.op != .Assign {
		result = compound_result(c, node, target, value)
	}
	// A binding that cannot take another value has been reported already. Measuring the value
	// against the one type that binding will ever have would only say the same thing twice.
	if writable && !fits(c, result, target) {
		report_types(c, .Type_Mismatch, span_of(c, node.value), result, target)
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

// check_mutable reports a write to a binding that cannot take another value, and answers whether
// the write may go ahead. parse has already rejected a target that is no place to write to at all.
@(private)
check_mutable :: proc(c: ^Checker, target: ast.Node_ID) -> (writable: bool) {
	identifier, is_ident := c.at.tree.nodes[target].variant.(ast.Ident)
	if !is_ident {
		return true // a field or an element, which `readonly` decides in T3.3
	}
	ref := resolve_name(c, target, identifier.name, .Value)
	if ref.symbol == bind.NO_SYMBOL {
		return true
	}
	if c.program.bound[ref.file].symbols[ref.symbol].kind == .Const {
		report(c, .Assign_To_Const, span_of(c, target), identifier.name)
		return false
	}
	return true
}

// Calls and arrows.

@(private)
check_call :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Call) -> Type_ID {
	callee := check_expression(c, node.callee)
	arguments := make([dynamic]Type_ID, 0, len(node.args), context.temp_allocator)
	for argument in node.args {
		append(&arguments, check_expression(c, argument))
	}

	if callee == ERROR {
		return ERROR
	}
	if callee == ANY {
		return ANY
	}
	function, is_function := c.table.types[callee].(Function)
	if !is_function {
		report(c, .Not_Callable, span_of(c, node.callee), text_of(c, callee))
		return ERROR
	}

	if !arity_fits(function, len(arguments)) {
		report(
			c,
			.Argument_Count,
			span_of(c, id),
			arity_text(c, function),
			count_text(c, len(arguments)),
		)
		return function.result
	}
	for argument, i in arguments {
		parameter := parameter_at(c, function, i)
		if !fits(c, argument, parameter) {
			report_types(c, .Type_Mismatch, span_of(c, node.args[i]), argument, parameter)
		}
	}
	return function.result
}

@(private)
arity_fits :: proc(function: Function, count: int) -> bool {
	if count < function.required {
		return false
	}
	return function.variadic || count <= len(function.params)
}

// parameter_at is the type the argument in that position is checked against. An argument that lands
// on a rest parameter is checked against the element type of `...xs: T[]`, which is an array type
// and so belongs to T3.3; until then it is the error type and takes anything.
@(private)
parameter_at :: proc(c: ^Checker, function: Function, index: int) -> Type_ID {
	last := len(function.params) - 1
	if function.variadic && index >= last {
		return ERROR
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

// check_arrow types an arrow, which is a value with a signature of its own. T3.3 gives its
// parameters their types from the call it is written in; until then each one needs an annotation.
@(private)
check_arrow :: proc(c: ^Checker, node: ast.Arrow) -> Type_ID {
	params, required, variadic := resolve_params(c, node.params)

	if node.return_type != ast.NO_NODE {
		result := resolve_type(c, node.return_type)
		check_body(c, node.body, result, nil)
		return function_type(&c.table, params, result, required, variadic)
	}

	returns := make([dynamic]Type_ID, 0, 4, context.temp_allocator)
	check_body(c, node.body, ERROR, &returns)
	result := inferred_result(c, node.body, returns[:])
	return function_type(&c.table, params, result, required, variadic)
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
	case Function:
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
