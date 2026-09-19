package parse

import "../ast"
import "../diag"
import "../source"

// Binary operator precedences, loosest first. `??` stands below `||` and `&&`; mixing it with
// them without parentheses is an error (T1009).
@(private)
COALESCE :: 1
@(private)
LOGICAL_OR :: 2
@(private)
LOGICAL_AND :: 3
@(private)
BIT_OR :: 4
@(private)
BIT_XOR :: 5
@(private)
BIT_AND :: 6
@(private)
EQUALITY :: 7
@(private)
RELATIONAL :: 8 // also `as`
@(private)
SHIFT :: 9
@(private)
ADDITIVE :: 10
@(private)
MULTIPLICATIVE :: 11
@(private)
POWER :: 12

// parse_expression parses an expression. The comma operator is outside the subset: `a, b` is one
// Bad node.
@(private)
parse_expression :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	expr := parse_assignment(p)
	if !at(p, .Comma) {
		return expr
	}
	report_subset(p, .Unsupported_Syntax, peek(p).span, "comma operators")
	for accept(p, .Comma) {
		parse_assignment(p)
	}
	return discard(p, m, start)
}

// parse_assignment parses an arrow function, an assignment or a conditional expression.
@(private)
parse_assignment :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return add_missing(p)
	}
	defer leave(p)

	if arrow := try_arrow(p); arrow != ast.NO_NODE {
		return arrow
	}
	m := mark(p)
	start := token_start(p)
	target := parse_conditional(p)
	start = covering_start(p, start, target)
	op, token_count, is_assignment := assignment_operator(p)
	if !is_assignment {
		return target
	}

	target_node := p.nodes[target]
	#partial switch _ in target_node.variant {
	case ast.Array_Literal, ast.Object_Literal:
		if op == .Assign {
			// `[a, b] = [b, a]`: a destructuring assignment.
			report_subset(p, .Destructuring, target_node.span)
			for _ in 0 ..< token_count {
				advance(p)
			}
			parse_assignment(p)
			return discard(p, m, start)
		}
	}
	if !is_assignable(target_node) {
		report_syntax(p, .Invalid_Assignment_Target, target_node.span)
	}
	for _ in 0 ..< token_count {
		advance(p)
	}
	value := parse_assignment(p)
	return add_node(p, start, ast.Assign{op = op, target = target, value = value})
}

// assignment_operator is the assignment operator at the current token and the number of tokens it
// takes: `>>=` and `>>>=` are several `>` and `=` tokens.
@(private)
assignment_operator :: proc(p: ^Parser) -> (op: ast.Assign_Op, token_count: int, ok: bool) {
	#partial switch peek(p).kind {
	case .Equal:
		return .Assign, 1, true
	case .Plus_Equal:
		return .Add, 1, true
	case .Minus_Equal:
		return .Subtract, 1, true
	case .Star_Equal:
		return .Multiply, 1, true
	case .Slash_Equal:
		return .Divide, 1, true
	case .Percent_Equal:
		return .Remainder, 1, true
	case .Star_Star_Equal:
		return .Power, 1, true
	case .Less_Less_Equal:
		return .Shift_Left, 1, true
	case .Amp_Equal:
		return .Bit_And, 1, true
	case .Bar_Equal:
		return .Bit_Or, 1, true
	case .Caret_Equal:
		return .Bit_Xor, 1, true
	case .Amp_Amp_Equal:
		return .And, 1, true
	case .Bar_Bar_Equal:
		return .Or, 1, true
	case .Question_Question_Equal:
		return .Coalesce, 1, true
	case .Greater:
		run := greater_run(p)
		if run.has_equal && run.greater_count == 2 {
			return .Shift_Right, 3, true
		}
		if run.has_equal && run.greater_count == 3 {
			return .Shift_Right_Unsigned, 4, true
		}
	}
	return
}

// Greater_Run describes the touching `>` and `=` tokens that start at the current `>`: tokenize
// leaves every `>` single, and they join here into `>=`, `>>`, `>>=`, `>>>` and `>>>=`.
@(private)
Greater_Run :: struct {
	greater_count: int, // 1 to 3
	has_equal:     bool, // a `=` touches the last `>`
}

@(private)
greater_run :: proc(p: ^Parser) -> (run: Greater_Run) {
	run.greater_count = 1
	for run.greater_count < 3 && touches_next(p, run.greater_count) {
		if peek(p, run.greater_count).kind != .Greater {
			break
		}
		run.greater_count += 1
	}
	count := run.greater_count
	run.has_equal = touches_next(p, count) && peek(p, count).kind == .Equal
	return
}

// touches_next reports whether the token ahead tokens after the current one starts right where
// the one before it ends, with no space between them.
@(private)
touches_next :: proc(p: ^Parser, ahead: int) -> bool {
	return peek(p, ahead - 1).span.end == peek(p, ahead).span.start
}

// is_assignable reports whether a node can be assigned to: a variable, a field or an element. A
// Bad node counts too: it has been reported already.
@(private)
is_assignable :: proc(node: ast.Node) -> bool {
	#partial switch _ in node.variant {
	case ast.Ident, ast.Member, ast.Index, ast.Non_Null, ast.Bad:
		return true
	}
	return false
}

@(private)
parse_conditional :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	condition := parse_binary(p, COALESCE)
	start = covering_start(p, start, condition)
	if !accept(p, .Question) {
		return condition
	}
	then_value := parse_assignment(p)
	expect(p, .Colon)
	else_value := parse_assignment(p)
	conditional := ast.Conditional {
		condition  = condition,
		then_value = then_value,
		else_value = else_value,
	}
	return add_node(p, start, conditional)
}

// parse_binary parses the binary operators of min_precedence and tighter, by precedence climbing.
// `as` binds like a relational operator, and its right side is a type.
@(private)
parse_binary :: proc(p: ^Parser, min_precedence: int) -> ast.Node_ID {
	if !enter(p) {
		return add_missing(p)
	}
	defer leave(p)

	m := mark(p)
	start := token_start(p)
	left := parse_unary(p)
	start = covering_start(p, start, left)
	for {
		token := peek(p)
		if RELATIONAL >= min_precedence && !token.line_break_before {
			is_as := is_word(token, "as")
			if is_as && peek(p, 1).kind == .Const {
				report_subset(p, .Unsupported_Syntax, token.span, "`as const` assertions")
				advance(p)
				advance(p)
				left = discard(p, m, start)
				continue
			}
			if is_as {
				advance(p)
				type := parse_type(p)
				left = add_node(p, start, ast.As{expr = left, type = type})
				continue
			}
			if is_word(token, "satisfies") {
				report_subset(p, .Unsupported_Syntax, advance(p).span, "`satisfies` expressions")
				parse_type(p)
				left = discard(p, m, start)
				continue
			}
		}
		if RELATIONAL >= min_precedence && (token.kind == .In || token.kind == .Instanceof) {
			what := "`in` expressions" if token.kind == .In else "`instanceof` expressions"
			report_subset(p, .Unsupported_Syntax, advance(p).span, what)
			parse_binary(p, RELATIONAL + 1)
			left = discard(p, m, start)
			continue
		}

		op, precedence, token_count, is_binary := binary_operator(p)
		if !is_binary || precedence < min_precedence {
			return left
		}
		if op == .Power {
			check_power_base(p, left, start)
		}
		for _ in 0 ..< token_count {
			advance(p)
		}
		right_start := token_start(p)
		// `**` is right-associative, the others left-associative.
		right_precedence := precedence if op == .Power else precedence + 1
		right := parse_binary(p, right_precedence)
		if mixes_coalesce(p, op, left, start) || mixes_coalesce(p, op, right, right_start) {
			report_syntax(p, .Mixed_Coalesce, token.span)
		}
		left = add_node(p, start, ast.Binary{op = op, left = left, right = right})
	}
}

// binary_operator is the binary operator at the current token, its precedence and the number of
// tokens it takes.
@(private)
binary_operator :: proc(
	p: ^Parser,
) -> (
	op: ast.Binary_Op,
	precedence: int,
	token_count: int,
	ok: bool,
) {
	#partial switch peek(p).kind {
	case .Question_Question:
		return .Coalesce, COALESCE, 1, true
	case .Bar_Bar:
		return .Or, LOGICAL_OR, 1, true
	case .Amp_Amp:
		return .And, LOGICAL_AND, 1, true
	case .Bar:
		return .Bit_Or, BIT_OR, 1, true
	case .Caret:
		return .Bit_Xor, BIT_XOR, 1, true
	case .Amp:
		return .Bit_And, BIT_AND, 1, true
	case .Equal_Equal:
		return .Equal, EQUALITY, 1, true
	case .Bang_Equal:
		return .Not_Equal, EQUALITY, 1, true
	case .Equal_Equal_Equal:
		return .Strict_Equal, EQUALITY, 1, true
	case .Bang_Equal_Equal:
		return .Strict_Not_Equal, EQUALITY, 1, true
	case .Less:
		return .Less, RELATIONAL, 1, true
	case .Less_Equal:
		return .Less_Equal, RELATIONAL, 1, true
	case .Greater:
		run := greater_run(p)
		switch {
		case run.has_equal && run.greater_count == 1:
			return .Greater_Equal, RELATIONAL, 2, true
		case run.has_equal:
			// `>>=` and `>>>=` are assignments.
			return
		case run.greater_count == 1:
			return .Greater, RELATIONAL, 1, true
		case run.greater_count == 2:
			return .Shift_Right, SHIFT, 2, true
		case:
			return .Shift_Right_Unsigned, SHIFT, 3, true
		}
	case .Less_Less:
		return .Shift_Left, SHIFT, 1, true
	case .Plus:
		return .Add, ADDITIVE, 1, true
	case .Minus:
		return .Subtract, ADDITIVE, 1, true
	case .Star:
		return .Multiply, MULTIPLICATIVE, 1, true
	case .Slash:
		return .Divide, MULTIPLICATIVE, 1, true
	case .Percent:
		return .Remainder, MULTIPLICATIVE, 1, true
	case .Star_Star:
		return .Power, POWER, 1, true
	}
	return
}

// check_power_base reports a unary expression as the left side of `**`: `-2 ** 2` could mean
// `(-2) ** 2` or `-(2 ** 2)`, so ECMAScript rejects it. start is where the left side starts; a
// left side in parentheses starts before its node.
@(private)
check_power_base :: proc(p: ^Parser, left: ast.Node_ID, start: i32) {
	node := p.nodes[left]
	unary, is_unary := node.variant.(ast.Unary)
	if !is_unary || node.span.start != start {
		return
	}
	text: string
	switch unary.op {
	case .Minus:
		text = "-"
	case .Plus:
		text = "+"
	case .Not:
		text = "!"
	case .Bit_Not:
		text = "~"
	case .Typeof:
		text = "typeof"
	}
	report_syntax(p, .Unary_Before_Power, node.span, text)
}

// mixes_coalesce reports whether operand, an operand of op that starts at operand_start, is a
// `??` next to `&&` or `||`, or an `&&` or `||` next to `??`, without parentheses around it.
@(private)
mixes_coalesce :: proc(
	p: ^Parser,
	op: ast.Binary_Op,
	operand: ast.Node_ID,
	operand_start: i32,
) -> bool {
	node := p.nodes[operand]
	binary, is_binary := node.variant.(ast.Binary)
	// Parentheses make no node: an operand in them starts before its node does.
	if !is_binary || node.span.start != operand_start {
		return false
	}
	is_logical :: proc(op: ast.Binary_Op) -> bool {
		return op == .And || op == .Or
	}
	if op == .Coalesce {
		return is_logical(binary.op)
	}
	return is_logical(op) && binary.op == .Coalesce
}

@(private)
parse_unary :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return add_missing(p)
	}
	defer leave(p)

	token := peek(p)
	start := token.span.start
	#partial switch token.kind {
	case .Minus, .Plus, .Bang, .Tilde, .Typeof:
		advance(p)
		operand := parse_unary(p)
		return add_node(p, start, ast.Unary{op = unary_op(token.kind), operand = operand})
	case .Plus_Plus, .Minus_Minus:
		advance(p)
		operand := parse_unary(p)
		check_update_target(p, operand)
		op: ast.Update_Op = .Pre_Increment if token.kind == .Plus_Plus else .Pre_Decrement
		return add_node(p, start, ast.Update{op = op, operand = operand})
	case .Delete:
		return parse_unsupported_unary(p, .Delete_Operator, "")
	case .Void:
		return parse_unsupported_unary(p, .Unsupported_Syntax, "`void` expressions")
	case .Await:
		return parse_unsupported_unary(p, .Async, "")
	case .Less:
		return parse_angle_brackets(p)
	}
	return parse_postfix(p)
}

@(private)
unary_op :: proc(kind: Token_Kind) -> ast.Unary_Op {
	#partial switch kind {
	case .Minus:
		return .Minus
	case .Plus:
		return .Plus
	case .Bang:
		return .Not
	case .Tilde:
		return .Bit_Not
	case .Typeof:
		return .Typeof
	}
	unreachable()
}

// parse_unsupported_unary reports a unary operator outside the subset and parses its operand.
@(private)
parse_unsupported_unary :: proc(p: ^Parser, code: diag.Code, arg: string) -> ast.Node_ID {
	m := mark(p)
	operator := advance(p)
	report_subset(p, code, operator.span, arg)
	parse_unary(p)
	return discard(p, m, operator.span.start)
}

// parse_angle_brackets parses `<T>x`, a type assertion, or `<T>(x: T) => x`, a generic arrow. Both
// are outside the subset.
@(private)
parse_angle_brackets :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	less := peek(p)
	parse_type_arguments(p)
	if try_arrow(p) != ast.NO_NODE {
		report_subset(p, .Unsupported_Syntax, less.span, "generic arrow functions")
	} else {
		report_subset(p, .Unsupported_Syntax, less.span, "`<T>` type assertions")
		parse_unary(p)
	}
	return discard(p, m, less.span.start)
}

// check_update_target reports the operand of `++` or `--` when it cannot be assigned to.
@(private)
check_update_target :: proc(p: ^Parser, operand: ast.Node_ID) {
	node := p.nodes[operand]
	if !is_assignable(node) {
		report_syntax(p, .Invalid_Assignment_Target, node.span)
	}
}

// parse_postfix parses a primary expression and what follows it: member access, indexing, calls,
// `!`, and a postfix `++` or `--`. Optional chaining and tagged templates are outside the subset.
@(private)
parse_postfix :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	expr := parse_primary(p)
	start = covering_start(p, start, expr)
	has_optional_chain := false
	loop: for {
		token := peek(p)
		#partial switch token.kind {
		case .Dot:
			advance(p)
			expr = add_node(p, start, ast.Member{object = expr, name = parse_member_name(p)})
		case .Question_Dot:
			// `a?.b`, `a?.[i]` or `a?.(x)`: the `[` and the `(` come around in the next turn. A
			// chain is one construct: only its first `?.` is reported.
			question_dot := advance(p)
			if !has_optional_chain {
				report_subset(p, .Optional_Chaining, question_dot.span)
			}
			has_optional_chain = true
			if !at(p, .Open_Bracket) && !at(p, .Open_Paren) {
				expr = add_node(p, start, ast.Member{object = expr, name = parse_member_name(p)})
			}
		case .Open_Bracket:
			advance(p)
			index := parse_expression(p)
			expect(p, .Close_Bracket)
			expr = add_node(p, start, ast.Index{object = expr, index = index})
		case .Open_Paren:
			args := parse_arguments(p)
			expr = add_node(p, start, ast.Call{callee = expr, args = args})
		case .Less:
			if !try_type_arguments(p) {
				break loop
			}
		case .Bang:
			if token.line_break_before {
				break loop
			}
			advance(p)
			expr = add_node(p, start, ast.Non_Null{expr = expr})
		case .Plus_Plus, .Minus_Minus:
			if token.line_break_before {
				break loop
			}
			advance(p)
			check_update_target(p, expr)
			op: ast.Update_Op = .Post_Increment if token.kind == .Plus_Plus else .Post_Decrement
			expr = add_node(p, start, ast.Update{op = op, operand = expr})
			break loop
		case .No_Substitution_Template, .Template_Head:
			report_subset(p, .Unsupported_Syntax, token.span, "tagged templates")
			parse_template(p)
			expr = discard(p, m, start)
		case:
			break loop
		}
	}
	if has_optional_chain {
		return discard(p, m, start)
	}
	return expr
}

// try_type_arguments reads `<T>` before the `(` of a call or a template: explicit type arguments,
// outside the subset. It reports them and drops them; the call stays. Otherwise the `<` is
// less-than: try_type_arguments reads nothing and returns false.
@(private)
try_type_arguments :: proc(p: ^Parser) -> bool {
	if p.current in p.failed_tries {
		return false
	}
	m := mark(p)
	less := peek(p)
	// A list that does not close with `>` is a syntax error too, so errors_seen tells both.
	parse_type_arguments(p)
	#partial switch peek(p).kind {
	case .Open_Paren, .No_Substitution_Template, .Template_Head:
		if p.errors_seen == m.errors_seen {
			drop(p, m)
			report_subset(p, .Unsupported_Syntax, less.span, "explicit type arguments")
			return true
		}
	}
	undo(p, m)
	return false
}

// parse_member_name parses the name after `.`: any name, a reserved word included.
@(private)
parse_member_name :: proc(p: ^Parser) -> ast.Name {
	if is_name_token(peek(p)) {
		return name_of(advance(p))
	}
	error_expected(p, "a name")
	return missing_name(p)
}

// parse_arguments parses the `(a, b)` of a call.
@(private)
parse_arguments :: proc(p: ^Parser) -> []ast.Node_ID {
	advance(p) // (
	first := len(p.scratch)
	for !at(p, .Close_Paren) && !at(p, .EOF) {
		append(&p.scratch, parse_element(p))
		if !accept(p, .Comma) {
			break
		}
	}
	expect(p, .Close_Paren)
	return finish_list(p, first)
}

// parse_element parses an argument or an array element: an expression, or a spread `...xs`, which
// is outside the subset and becomes a Bad node.
@(private)
parse_element :: proc(p: ^Parser) -> ast.Node_ID {
	if !at(p, .Dot_Dot_Dot) {
		return parse_assignment(p)
	}
	m := mark(p)
	spread := advance(p)
	report_subset(p, .Spread, spread.span)
	parse_assignment(p)
	return discard(p, m, spread.span.start)
}

@(private)
parse_primary :: proc(p: ^Parser) -> ast.Node_ID {
	if !enter(p) {
		return add_missing(p)
	}
	defer leave(p)

	token := peek(p)
	start := token.span.start
	#partial switch token.kind {
	case .Identifier:
		if is_word(token, "async") && peek(p, 1).kind == .Function && next_on_same_line(p) {
			return parse_function_expression(p)
		}
		return add_identifier(p, advance(p))
	case .Number:
		advance(p)
		return add_node(p, start, ast.Number_Literal{value = token.value.(f64)})
	case .String:
		advance(p)
		return add_node(p, start, ast.String_Literal{value = token.value.(string)})
	case .No_Substitution_Template, .Template_Head:
		return parse_template(p)
	case .True, .False:
		advance(p)
		return add_node(p, start, ast.Bool_Literal{value = token.kind == .True})
	case .Null:
		advance(p)
		return add_node(p, start, ast.Null_Literal{})
	case .Open_Paren:
		// Parentheses make no node.
		advance(p)
		expr := parse_expression(p)
		expect(p, .Close_Paren)
		return expr
	case .Open_Bracket:
		return parse_array_literal(p)
	case .Open_Brace:
		return parse_object_literal(p)
	case .Function:
		return parse_function_expression(p)
	case .Class:
		return parse_class(p, start)
	case .New:
		return parse_new(p)
	case .This, .Super:
		report_subset(p, .Class, advance(p).span)
		return add_node(p, start, ast.Bad{})
	case .Slash, .Slash_Equal:
		return parse_regular_expression(p)
	case .Import:
		what := "`import()` and `import.meta` expressions"
		report_subset(p, .Unsupported_Syntax, advance(p).span, what)
		return add_node(p, start, ast.Bad{})
	case .Yield:
		m := mark(p)
		report_subset(p, .Unsupported_Syntax, advance(p).span, "generators")
		next := peek(p)
		if !next.line_break_before && can_start_expression(next.kind) {
			parse_assignment(p)
		}
		return discard(p, m, start)
	}
	error_expected(p, "an expression")
	return add_missing(p)
}

// can_start_expression reports the tokens that start an expression, the ones parse_primary and
// parse_unary take.
@(private)
can_start_expression :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Identifier,
	     .Number,
	     .String,
	     .No_Substitution_Template,
	     .Template_Head,
	     .Open_Paren,
	     .Open_Bracket,
	     .Open_Brace,
	     .Plus,
	     .Minus,
	     .Bang,
	     .Tilde,
	     .Plus_Plus,
	     .Minus_Minus,
	     .Less,
	     .Slash,
	     .Slash_Equal,
	     .True,
	     .False,
	     .Null,
	     .This,
	     .Super,
	     .New,
	     .Function,
	     .Class,
	     .Typeof,
	     .Void,
	     .Delete,
	     .Await,
	     .Yield,
	     .Import:
		return true
	}
	return false
}

// add_identifier adds the node for a use of a name: an Ident, or a Bad node for `arguments` and
// `eval`, which are outside the subset.
@(private)
add_identifier :: proc(p: ^Parser, token: Token) -> ast.Node_ID {
	name := token.value.(string)
	switch name {
	case "arguments":
		report_subset(p, .Arguments_Object, token.span)
		return add_node_at(p, token.span, ast.Bad{})
	case "eval":
		report_subset(p, .Eval, token.span)
		return add_node_at(p, token.span, ast.Bad{})
	}
	return add_node_at(p, token.span, ast.Ident{name = name})
}

// parse_template parses `a${x}b${y}c`: the text parts from the template tokens, the expressions
// between them.
@(private)
parse_template :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	head := advance(p)
	parts := make([dynamic]string, 0, 1, p.allocator)
	append(&parts, head.value.(string))
	first := len(p.scratch)
	for part := head; part.kind == .Template_Head || part.kind == .Template_Middle; {
		append(&p.scratch, parse_expression(p))
		part = next_template_part(p)
		text, _ := part.value.(string)
		append(&parts, text)
	}
	template := ast.Template {
		parts       = parts[:],
		expressions = finish_list(p, first),
	}
	return add_node(p, start, template)
}

// next_template_part consumes the Template_Middle or Template_Tail that ends a substitution. When
// something else comes first, the `}` is reported missing and the tokens up to this template's next
// part are skipped; at the end of the text the result is the EOF token, whose text is empty.
@(private)
next_template_part :: proc(p: ^Parser) -> Token {
	if !at(p, .Template_Middle) && !at(p, .Template_Tail) {
		error_expected(p, "`}`")
	}
	depth := 0 // templates nested in the skipped tokens
	for {
		token := peek(p)
		#partial switch token.kind {
		case .EOF:
			return token
		case .Template_Head:
			depth += 1
		case .Template_Middle:
			if depth == 0 {
				return advance(p)
			}
		case .Template_Tail:
			if depth == 0 {
				return advance(p)
			}
			depth -= 1
		}
		advance(p)
	}
}

// parse_array_literal parses `[a, b]`. A hole `[a, , b]` is outside the subset: arrays have no
// holes (requirements 3.6).
@(private)
parse_array_literal :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	advance(p) // [
	first := len(p.scratch)
	for !at(p, .Close_Bracket) && !at(p, .EOF) {
		if at(p, .Comma) {
			report_subset(p, .Unsupported_Syntax, advance(p).span, "array holes")
			continue
		}
		append(&p.scratch, parse_element(p))
		if !accept(p, .Comma) {
			break
		}
	}
	expect(p, .Close_Bracket)
	return add_node(p, start, ast.Array_Literal{elements = finish_list(p, first)})
}

// parse_object_literal parses `{ a: 1, "b": 2, c }`. A member outside the subset is reported and
// left out.
@(private)
parse_object_literal :: proc(p: ^Parser) -> ast.Node_ID {
	start := token_start(p)
	advance(p) // {
	first := len(p.scratch)
	for !at(p, .Close_Brace) && !at(p, .EOF) {
		property := parse_property(p)
		if property != ast.NO_NODE {
			append(&p.scratch, property)
		}
		if !accept(p, .Comma) {
			break
		}
	}
	expect(p, .Close_Brace)
	return add_node(p, start, ast.Object_Literal{properties = finish_list(p, first)})
}

// parse_property parses one member of an object literal: `name: value` or the shorthand `name`. A
// member outside the subset is reported and skipped; the result is NO_NODE then.
@(private)
parse_property :: proc(p: ^Parser) -> ast.Node_ID {
	token := peek(p)
	next := peek(p, 1)
	#partial switch token.kind {
	case .Dot_Dot_Dot:
		m := mark(p)
		report_subset(p, .Spread, advance(p).span)
		parse_assignment(p)
		drop(p, m)
		return ast.NO_NODE
	case .Open_Bracket:
		return skip_property(p, .Unsupported_Syntax, token.span, "computed property names")
	case .Number:
		return skip_property(p, .Unsupported_Syntax, token.span, "number property keys")
	case .Star:
		return skip_property(p, .Unsupported_Syntax, token.span, "generators")
	}
	is_accessor := (is_word(token, "get") || is_word(token, "set")) && starts_member_name(next)
	if is_accessor {
		return skip_property(p, .Unsupported_Syntax, token.span, "getters and setters")
	}
	if is_word(token, "async") && starts_member_name(next) && !next.line_break_before {
		return skip_property(p, .Async, token.span, "")
	}
	if !is_name_token(token) && token.kind != .String {
		error_expected(p, "a property name")
		return ast.NO_NODE
	}

	advance(p)
	name := ast.Name {
		text = token.value.(string),
		span = token.span,
	}
	#partial switch peek(p).kind {
	case .Colon:
		advance(p)
		value := parse_assignment(p)
		return add_node(p, token.span.start, ast.Property{name = name, value = value})
	case .Open_Paren, .Less:
		return skip_property(p, .Function_Expression, token.span, "object literal methods")
	}
	// The shorthand `{x}`: the value is the variable x.
	if token.kind != .Identifier {
		error_expected(p, "`:`")
		return ast.NO_NODE
	}
	if at(p, .Equal) {
		// `{x = 1}` is a destructuring pattern with a default value.
		m := mark(p)
		report_subset(p, .Destructuring, advance(p).span)
		parse_assignment(p)
		drop(p, m)
	}
	value := add_identifier(p, token)
	return add_node(p, token.span.start, ast.Property{name = name, value = value})
}

// skip_property reports a member of an object literal that is outside the subset, at span, and
// skips it up to the `,` after it or the closing `}`: a value may go on over several lines. The
// result is NO_NODE: the member is left out of its list.
@(private)
skip_property :: proc(p: ^Parser, code: diag.Code, span: source.Span, arg: string) -> ast.Node_ID {
	report_subset(p, code, span, arg)
	for {
		#partial switch peek(p).kind {
		case .Comma, .Semicolon, .Close_Brace, .EOF:
			return ast.NO_NODE
		case .Open_Paren, .Open_Bracket, .Open_Brace, .Template_Head:
			skip_balanced(p)
			continue
		}
		advance(p)
	}
}

// starts_member_name reports whether token can start the name of an object member, after a
// modifier such as `get` or `readonly`.
@(private)
starts_member_name :: proc(token: Token) -> bool {
	#partial switch token.kind {
	case .String, .Number, .Open_Bracket:
		return true
	}
	return is_name_token(token)
}

// parse_new reports `new`: `new Function(...)` is a "never" rule, any other `new` a class
// construct outside the subset.
@(private)
parse_new :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	keyword := advance(p)
	start := keyword.span.start
	if at(p, .Dot) {
		report_subset(p, .Unsupported_Syntax, keyword.span, "`new.target` expressions")
		advance(p)
		parse_member_name(p)
		return discard(p, m, start)
	}
	if at_word(p, "Function") && peek(p, 1).kind != .Dot {
		report_subset(p, .New_Function, keyword.span)
	} else {
		report_subset(p, .New_Expression, keyword.span)
	}

	// The class: a name and member accesses, then type arguments and arguments.
	parse_primary(p)
	for accept(p, .Dot) {
		parse_member_name(p)
	}
	if at(p, .Less) {
		parse_type_arguments(p)
	}
	if at(p, .Open_Paren) {
		parse_arguments(p)
	}
	return discard(p, m, start)
}

// parse_function_expression reports a function expression, `async` included, and parses it, so
// that the errors inside it are found too.
@(private)
parse_function_expression :: proc(p: ^Parser) -> ast.Node_ID {
	m := mark(p)
	start := token_start(p)
	if at_word(p, "async") {
		report_subset(p, .Async, advance(p).span)
	}
	report_subset(p, .Function_Expression, advance(p).span, "function expressions")
	accept(p, .Star)
	name: ast.Name
	if at(p, .Identifier) {
		name = name_of(advance(p))
	}
	parse_function_rest(p, start, {}, name)
	return discard(p, m, start)
}

// parse_regular_expression reports a regular expression and skips it. tokenize reads its `/` as
// division, so the literal is the tokens up to the next `/` on the same line, and the flags glued
// to it. The diagnostic spans the whole literal: parse_file drops the tokenizer's errors inside it.
@(private)
parse_regular_expression :: proc(p: ^Parser) -> ast.Node_ID {
	slash := advance(p)
	for !at(p, .EOF) && !peek(p).line_break_before {
		token := advance(p)
		if token.kind == .Slash || token.kind == .Slash_Equal {
			break
		}
	}
	flags := peek(p)
	if flags.kind == .Identifier && flags.span.start == previous_end(p) {
		advance(p)
	}
	literal := source.Span {
		file  = p.file,
		start = slash.span.start,
		end   = previous_end(p),
	}
	report_subset(p, .Regular_Expression, literal)
	return add_node_at(p, literal, ast.Bad{})
}

// Arrow functions.

// try_arrow parses an arrow function if one starts at the current token. Otherwise it returns
// NO_NODE and reads nothing.
@(private)
try_arrow :: proc(p: ^Parser) -> ast.Node_ID {
	token := peek(p)
	next := peek(p, 1)
	#partial switch token.kind {
	case .Identifier:
		if next.kind == .Arrow && !next.line_break_before {
			return parse_arrow_with_name(p)
		}
		is_async_head := next.kind == .Identifier || next.kind == .Open_Paren
		if is_word(token, "async") && is_async_head && !next.line_break_before {
			return try_async_arrow(p)
		}
	case .Open_Paren:
		return try_parenthesized_arrow(p)
	}
	return ast.NO_NODE
}

// parse_arrow_with_name parses `x => body`.
@(private)
parse_arrow_with_name :: proc(p: ^Parser) -> ast.Node_ID {
	token := advance(p)
	name := name_of(token)
	check_binding_name(p, name)
	param := add_node_at(p, token.span, ast.Param{name = name})
	return finish_arrow(p, token.span.start, one_element(p, param), ast.NO_NODE)
}

// try_async_arrow parses `async x => body` or `async (x) => body`, outside the subset. `async(x)`
// alone is a call of a function named async: then nothing is read.
@(private)
try_async_arrow :: proc(p: ^Parser) -> ast.Node_ID {
	if p.current in p.failed_tries {
		return ast.NO_NODE
	}
	m := mark(p)
	async := advance(p)
	if try_arrow(p) == ast.NO_NODE {
		undo(p, m)
		return ast.NO_NODE
	}
	report_subset(p, .Async, async.span)
	return discard(p, m, async.span.start)
}

// try_parenthesized_arrow parses `(params) => body` or `(params): type => body`. A `(` whose `)` is
// followed by `=>` starts an arrow for sure. One followed by `:` may also be a parenthesized
// expression, as in `c ? (x) : y`: that case is tried from a Mark and undone when no `=>` comes.
@(private)
try_parenthesized_arrow :: proc(p: ^Parser) -> ast.Node_ID {
	if p.current in p.failed_tries {
		return ast.NO_NODE
	}
	close := matching_close(p, p.current)
	if close < 0 {
		return ast.NO_NODE
	}
	after := p.tokens[close + 1]
	is_arrow := after.kind == .Arrow && !after.line_break_before
	if !is_arrow && after.kind != .Colon {
		return ast.NO_NODE
	}

	m := mark(p)
	start := token_start(p)
	params := parse_params(p)
	return_type := ast.NO_NODE
	if accept(p, .Colon) {
		return_type = parse_type(p)
	}
	head_fits := at(p, .Arrow) && !peek(p).line_break_before && p.errors_seen == m.errors_seen
	if !is_arrow && !head_fits {
		undo(p, m)
		return ast.NO_NODE
	}
	return finish_arrow(p, start, params, return_type)
}

// finish_arrow parses the `=> body` of an arrow. A body that starts with `{` is a block; an object
// literal body needs parentheses: `() => ({})`.
@(private)
finish_arrow :: proc(
	p: ^Parser,
	start: i32,
	params: []ast.Node_ID,
	return_type: ast.Node_ID,
) -> ast.Node_ID {
	expect(p, .Arrow)
	body: ast.Node_ID
	if at(p, .Open_Brace) {
		body = parse_block(p)
	} else {
		body = parse_assignment(p)
	}
	arrow := ast.Arrow {
		params      = params,
		return_type = return_type,
		body        = body,
	}
	return add_node(p, start, arrow)
}
