/*
Source text to a syntax tree, in two public stages: tokenize turns the text of one file into a
token array (tokenize.odin has its rules), and parse_tokens turns the tokens into an ast.File_AST.
parse_file runs both. A stage never stops at an error: it reports a diag.Diagnostic and goes on.

Parsing (parse_tokens):
- Recursive descent over the token array, one procedure per grammar rule: statements.odin,
  expressions.odin and types.odin. Binary operators go by precedence climbing. Lookahead is a
  look at the array: an arrow with a return type `(a): T =>` and type arguments `f<T>(x)` are tried
  from a Mark and undone when they do not fit.
- A `>` token is always single. Where a binary or assignment operator is expected, touching `>`
  and `=` tokens join into `>=`, `>>`, `>>>`, `>>=` and `>>>=`; a type never joins them, so `>>`
  closes two type argument lists.
- Contextual keywords (`type`, `declare`, `namespace`, `async`, `as`, `of`, `from`...) are names
  that parse_tokens tells apart by their text. A declaration keyword counts only when the next token
  is on the same line: `type` and then `X = 1` on the next line are two expression statements.
- Automatic semicolon insertion follows ECMAScript: a `;` may be left out before `}`, at the end of
  the file and before a token on a new line. A line break is not allowed before a postfix `++`,
  `--` or `!`, before `as` and `=>`, and after `return`, `break` and `continue`.

Subset rules (requirements 2.2 and 2.3): the "never" constructs (`var`, `with`, `namespace`,
decorators, `arguments`, `delete`, `eval`, `new Function`) and the other constructs outside v1 are
parsed through, so that the errors inside them are found too, and then replaced by one Bad node
with a T2xxx diagnostic. Where a v1 node can carry the rest, parse keeps it and drops only the
unsupported part, for example a default parameter value, a destructuring pattern (the Name stays
empty), the type arguments of a call, a label, an object member.

Errors and recovery: a missing token is reported and not consumed, at the end of the line before
when the next token starts a new line; a missing expression or type is a zero-width Bad node. A
statement without its `;` skips to the next statement: past the next `;`, to a `}`, to a token on
a new line that starts a statement, or to the end, over balanced brackets; an unclosed bracket is
skipped alone. Only the first syntax error (T1xxx) of a line is reported, since the next ones on
that line are most likely its consequences, as in go/parser; T2xxx are always reported.

Memory: the token array, the node array, every list, every allocated string and the diagnostics
are allocated with the allocator passed in, which is meant to be an arena: parse never frees. Names
and string values borrow the source text or tokenize's cooked values. Scratch data goes to
context.temp_allocator.
*/
package parse

import "base:runtime"
import "core:slice"
import "core:strings"

import "../ast"
import "../diag"
import "../source"

// parse_file parses text, the text of file: tokenize, then parse_tokens. diagnostics has the
// tokenizer's diagnostics first, then the parser's; a tokenizer error inside a regular expression
// literal is left out, since the literal is reported as a whole.
parse_file :: proc(
	text: string,
	file: source.File_ID,
	allocator := context.allocator,
) -> (
	tree: ast.File_AST,
	diagnostics: []diag.Diagnostic,
) {
	// direct: the token array stays in the allocator (the task arena) until the end of the build;
	// tokenize gets a second allocator for it if the memory ever matters.
	tokens, token_diagnostics := tokenize(text, file, allocator)
	parse_diagnostics: []diag.Diagnostic
	tree, parse_diagnostics = parse_tokens(tokens, allocator)

	all := make(
		[dynamic]diag.Diagnostic,
		0,
		len(token_diagnostics) + len(parse_diagnostics),
		allocator,
	)
	for d in token_diagnostics {
		if !inside_regular_expression(d.span, parse_diagnostics) {
			append(&all, d)
		}
	}
	append(&all, ..parse_diagnostics)
	return tree, all[:]
}

// inside_regular_expression reports whether span lies in a regular expression literal that parse
// reported. tokenize reads the literal as ordinary tokens, and its errors there (a `\` is no
// token) would only repeat that report.
@(private)
inside_regular_expression :: proc(span: source.Span, diagnostics: []diag.Diagnostic) -> bool {
	for d in diagnostics {
		is_inside := d.span.start <= span.start && span.end <= d.span.end
		if d.code == .Regular_Expression && is_inside {
			return true
		}
	}
	return false
}

// parse_tokens builds the syntax tree of the tokens of one file, as tokenize returns them: the
// file is the one of the EOF token. It reports every problem it finds as a diagnostic and always
// returns a whole tree.
parse_tokens :: proc(
	tokens: []Token,
	allocator := context.allocator,
) -> (
	tree: ast.File_AST,
	diagnostics: []diag.Diagnostic,
) {
	ensure(len(tokens) > 0 && tokens[len(tokens) - 1].kind == .EOF)
	eof := tokens[len(tokens) - 1]

	p := Parser {
		tokens           = tokens,
		file             = eof.span.file,
		allocator        = allocator,
		nodes            = make([dynamic]ast.Node, 0, len(tokens) + 1, allocator),
		scratch          = make([dynamic]ast.Node_ID, context.temp_allocator),
		diagnostics      = make([dynamic]diag.Diagnostic, allocator),
		last_error_start = -1,
		failed_tries     = make(map[int]struct{}, context.temp_allocator),
	}
	defer delete(p.scratch)
	defer delete(p.failed_tries)

	append(&p.nodes, ast.Node{}) // ROOT, filled in last
	statements := parse_module_items(&p, .EOF)
	p.nodes[ast.ROOT] = {
		span = {file = p.file, start = 0, end = eof.span.end},
		variant = ast.Module{statements = statements},
	}

	tree = {
		file    = p.file,
		nodes   = p.nodes[:],
		imports = module_requests(p.nodes[:], statements, allocator),
	}
	return tree, p.diagnostics[:]
}

// Parser is the state of one parse_tokens call.
@(private)
Parser :: struct {
	tokens:           []Token,
	file:             source.File_ID,
	allocator:        runtime.Allocator,
	current:          int, // index of the next token to read
	nodes:            [dynamic]ast.Node,
	// The elements of the lists under construction, the innermost list last; see finish_list.
	scratch:          [dynamic]ast.Node_ID,
	diagnostics:      [dynamic]diag.Diagnostic,
	// Every syntax error counts, also one that report_syntax drops, so that a try from a Mark
	// knows whether it failed.
	errors_seen:      int,
	// Where the last reported syntax error starts, or -1.
	last_error_start: i32,
	// The tokens where a try (an arrow head, type arguments) failed. A try reads only the tokens
	// after its start, so it fails there again: remembering it keeps nested tries from repeating
	// each other's work, which grows exponentially with the depth.
	failed_tries:     map[int]struct{},
	depth:            int, // see enter
}

// MAX_DEPTH bounds how deep the recursive procedures nest, well below a stack overflow in a debug
// build on a 1 MB stack. A level of brackets takes about four, a nested type or function two, an
// `else if` one.
@(private)
MAX_DEPTH :: 256

// enter counts one level of recursion; each procedure that recurses calls it first, and leave on
// the way out. Past MAX_DEPTH the code is reported as too deep and the parser jumps to the end of
// the file, so that every procedure on the stack returns.
@(private)
enter :: proc(p: ^Parser) -> bool {
	if p.depth < MAX_DEPTH {
		p.depth += 1
		return true
	}
	report_syntax(p, .Nesting_Too_Deep, peek(p).span)
	p.current = len(p.tokens) - 1
	// The errors of the constructs left open at the end would only repeat it.
	p.last_error_start = peek(p).span.start
	return false
}

@(private)
leave :: proc(p: ^Parser) {
	p.depth -= 1
}

// Mark is a parser position to come back to: undo returns to it, dropping everything parsed
// since; drop and discard remove only the nodes, so the diagnostics stay.
@(private)
Mark :: struct {
	current:          int,
	node_count:       int,
	scratch_count:    int,
	diagnostic_count: int,
	errors_seen:      int,
	last_error_start: i32,
}

@(private)
mark :: proc(p: ^Parser) -> Mark {
	return {
		current = p.current,
		node_count = len(p.nodes),
		scratch_count = len(p.scratch),
		diagnostic_count = len(p.diagnostics),
		errors_seen = p.errors_seen,
		last_error_start = p.last_error_start,
	}
}

// undo returns to m as if nothing was parsed since, and remembers that the try from m failed.
@(private)
undo :: proc(p: ^Parser, m: Mark) {
	p.current = m.current
	resize(&p.nodes, m.node_count)
	resize(&p.scratch, m.scratch_count)
	resize(&p.diagnostics, m.diagnostic_count)
	p.errors_seen = m.errors_seen
	p.last_error_start = m.last_error_start
	p.failed_tries[m.current] = {}
}

// drop removes the nodes parsed since m. Nothing refers to them yet: a parent is added after its
// children, and the lists in progress hold only older nodes.
@(private)
drop :: proc(p: ^Parser, m: Mark) {
	resize(&p.nodes, m.node_count)
}

// discard replaces the nodes parsed since m with one Bad node over the text from start, for a
// construct outside the subset that has been reported.
@(private)
discard :: proc(p: ^Parser, m: Mark, start: i32) -> ast.Node_ID {
	drop(p, m)
	return add_node(p, start, ast.Bad{})
}

// Tokens.

// peek returns the token ahead tokens after the current one; past the end it is the EOF token.
@(private)
peek :: proc(p: ^Parser, ahead := 0) -> Token {
	return p.tokens[min(p.current + ahead, len(p.tokens) - 1)]
}

// advance consumes the current token and returns it. It never moves past EOF.
@(private)
advance :: proc(p: ^Parser) -> Token {
	token := p.tokens[p.current]
	if token.kind != .EOF {
		p.current += 1
	}
	return token
}

@(private)
at :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	return p.tokens[p.current].kind == kind
}

// at_word reports whether the current token is the name word, which may be a contextual keyword.
@(private)
at_word :: proc(p: ^Parser, word: string) -> bool {
	return is_word(peek(p), word)
}

@(private)
is_word :: proc(token: Token, word: string) -> bool {
	return token.kind == .Identifier && token.value.(string) == word
}

// is_name_token reports whether token can be a property or member name: a name or a reserved word.
@(private)
is_name_token :: proc(token: Token) -> bool {
	// The reserved words end Token_Kind, from .Await to .Yield.
	#assert(max(Token_Kind) == .Yield)
	return token.kind == .Identifier || token.kind >= .Await
}

// next_on_same_line reports whether the token after the current one has no line break before it.
@(private)
next_on_same_line :: proc(p: ^Parser) -> bool {
	next := peek(p, 1)
	return next.kind != .EOF && !next.line_break_before
}

@(private)
accept :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if !at(p, kind) {
		return false
	}
	advance(p)
	return true
}

@(private)
accept_word :: proc(p: ^Parser, word: string) -> bool {
	if !at_word(p, word) {
		return false
	}
	advance(p)
	return true
}

// expect consumes a punctuator of kind, or reports it missing and leaves the current token.
@(private)
expect :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if accept(p, kind) {
		return true
	}
	error_expected(p, quoted(p, punctuator_text(kind)))
	return false
}

@(private)
expect_word :: proc(p: ^Parser, word: string) -> bool {
	if accept_word(p, word) {
		return true
	}
	error_expected(p, quoted(p, word))
	return false
}

// token_start is where the current token starts: the start of the node that begins with it.
@(private)
token_start :: proc(p: ^Parser) -> i32 {
	return p.tokens[p.current].span.start
}

// previous_end is where the last consumed token ends: the end of the node that ends with it.
@(private)
previous_end :: proc(p: ^Parser) -> i32 {
	return p.tokens[p.current - 1].span.end if p.current > 0 else 0
}

// matching_close is the index of the token that closes the bracket at index open. It is -1 for an
// unclosed bracket: the text ends first, or a closing bracket of a kind with none open comes first,
// such as the `}` of the enclosing block. A template substitution counts as a bracket: `${`
// opens, the tail closes.
@(private)
matching_close :: proc(p: ^Parser, open: int) -> int {
	depths: [4]int // open (, [, { and ${
	for token, i in p.tokens[open:] {
		kind, delta := 0, 0
		#partial switch token.kind {
		case .Open_Paren:
			kind, delta = 0, 1
		case .Close_Paren:
			kind, delta = 0, -1
		case .Open_Bracket:
			kind, delta = 1, 1
		case .Close_Bracket:
			kind, delta = 1, -1
		case .Open_Brace:
			kind, delta = 2, 1
		case .Close_Brace:
			kind, delta = 2, -1
		case .Template_Head:
			kind, delta = 3, 1
		case .Template_Tail:
			kind, delta = 3, -1
		case:
			continue
		}
		if depths[kind] + delta < 0 {
			return -1
		}
		depths[kind] += delta
		if depths == {} {
			return open + i
		}
	}
	return -1
}

// skip_balanced skips the bracket at the current token and everything up to its closing bracket.
// An unclosed bracket is skipped alone, so that the text after it still parses.
@(private)
skip_balanced :: proc(p: ^Parser) {
	close := matching_close(p, p.current)
	if close < 0 {
		advance(p)
		return
	}
	for p.current <= close {
		advance(p)
	}
}

// Nodes.

// add_node appends a node that spans the text from start to the end of the last consumed token.
// A node that consumed nothing is zero-width at that end, like add_missing.
@(private)
add_node :: proc(p: ^Parser, start: i32, variant: ast.Variant) -> ast.Node_ID {
	end := previous_end(p)
	return add_node_at(p, {file = p.file, start = min(start, end), end = end}, variant)
}

// covering_start is the start of a node whose first token starts at start and whose first child
// is first. It is start, except when first is missing: add_missing puts it before that token,
// and the node must cover it.
@(private)
covering_start :: proc(p: ^Parser, start: i32, first: ast.Node_ID) -> i32 {
	return min(start, p.nodes[first].span.start)
}

@(private)
add_node_at :: proc(p: ^Parser, span: source.Span, variant: ast.Variant) -> ast.Node_ID {
	id := ast.Node_ID(len(p.nodes))
	append(&p.nodes, ast.Node{span = span, variant = variant})
	return id
}

// add_missing adds a zero-width Bad node where a missing expression or type would have ended, after
// the last consumed token, so that it lies inside its parent.
@(private)
add_missing :: proc(p: ^Parser) -> ast.Node_ID {
	end := previous_end(p)
	return add_node_at(p, {file = p.file, start = end, end = end}, ast.Bad{})
}

// finish_list copies the scratch elements from first on into a list and removes them from scratch:
//
//	first := len(p.scratch)
//	for ... { append(&p.scratch, element) }
//	elements := finish_list(p, first)
@(private)
finish_list :: proc(p: ^Parser, first: int) -> []ast.Node_ID {
	list := slice.clone(p.scratch[first:], p.allocator)
	resize(&p.scratch, first)
	return list
}

@(private)
one_element :: proc(p: ^Parser, id: ast.Node_ID) -> []ast.Node_ID {
	list := make([]ast.Node_ID, 1, p.allocator)
	list[0] = id
	return list
}

@(private)
name_of :: proc(token: Token) -> ast.Name {
	return {text = token.value.(string), span = token.span}
}

// missing_name is the empty Name of a declaration whose name is missing or not supported.
@(private)
missing_name :: proc(p: ^Parser) -> ast.Name {
	end := previous_end(p)
	return {span = {file = p.file, start = end, end = end}}
}

// module_requests lists the imports and re-exports among the top-level statements, the requests
// that driver follows.
@(private)
module_requests :: proc(
	nodes: []ast.Node,
	statements: []ast.Node_ID,
	allocator: runtime.Allocator,
) -> []ast.Node_ID {
	requests := make([dynamic]ast.Node_ID, allocator)
	for id in statements {
		#partial switch v in nodes[id].variant {
		case ast.Import_Named, ast.Import_Namespace:
			append(&requests, id)
		case ast.Export_Named:
			if v.path != ast.NO_NODE {
				append(&requests, id)
			}
		}
	}
	return requests[:]
}

// Diagnostics.

// error_expected reports that what (a quoted token, "a name", "an expression") is missing before
// the current token. When that token starts a new line, the error stands at the end of the line
// before, where the missing part belongs, so that it does not hide an error on the new line.
@(private)
error_expected :: proc(p: ^Parser, what: string) {
	token := peek(p)
	span := token.span
	if token.line_break_before && token.kind != .EOF {
		end := previous_end(p)
		span = {
			file  = p.file,
			start = end,
			end   = end,
		}
	}
	report_syntax(p, .Expected_Token, span, what, describe_token(p, token))
}

@(private)
error_unexpected :: proc(p: ^Parser) {
	token := peek(p)
	report_syntax(p, .Unexpected_Token, token.span, describe_token(p, token))
}

// report_syntax reports a syntax error (T1xxx) unless one was reported on the same line: a second
// error on a line is most likely a consequence of the first.
@(private)
report_syntax :: proc(p: ^Parser, code: diag.Code, span: source.Span, args: ..string) {
	p.errors_seen += 1
	last := p.last_error_start
	if last >= 0 && !line_break_between(p, last, span.start) {
		return
	}
	p.last_error_start = span.start
	d := diag.Diagnostic {
		code = code,
		span = span,
	}
	copy(d.args[:], args)
	append(&p.diagnostics, d)
}

// report_subset reports a construct outside the subset (T2xxx). These are always reported: each
// is a separate thing to rewrite.
@(private)
report_subset :: proc(p: ^Parser, code: diag.Code, span: source.Span, arg := "") {
	append(&p.diagnostics, diag.Diagnostic{code = code, span = span, args = {0 = arg}})
}

// report_unsupported reports a construct outside the subset that has no code of its own.
@(private)
report_unsupported :: proc(p: ^Parser, construct: diag.Construct, span: source.Span) {
	report_subset(p, .Unsupported_Syntax, span, diag.construct_text(construct))
}

// line_break_between reports whether a line break lies between the offsets a and b, in either
// order: whether a token that starts after the first and at or before the second follows one.
@(private)
line_break_between :: proc(p: ^Parser, a, b: i32) -> bool {
	low, high := min(a, b), max(a, b)
	// The first token that starts after low, by binary search.
	first, count := 0, len(p.tokens)
	for count > 0 {
		half := count / 2
		if p.tokens[first + half].span.start <= low {
			first += half + 1
			count -= half + 1
		} else {
			count = half
		}
	}
	for token in p.tokens[first:] {
		if token.span.start > high {
			break
		}
		if token.line_break_before {
			return true
		}
	}
	return false
}

// describe_token names a token in a message: "`;`", "`class`", "`x`", "a number", "end of file".
@(private)
describe_token :: proc(p: ^Parser, token: Token) -> string {
	#partial switch token.kind {
	case .EOF:
		return "end of file"
	case .Number:
		return "a number"
	case .String:
		return "a string"
	case .No_Substitution_Template, .Template_Head, .Template_Middle, .Template_Tail:
		return "a template"
	}
	if is_name_token(token) {
		return quoted(p, token.value.(string))
	}
	return quoted(p, punctuator_text(token.kind))
}

// punctuator_text is the spelling of a punctuator kind.
@(private)
punctuator_text :: proc(kind: Token_Kind) -> string {
	for punctuator in PUNCTUATORS {
		if punctuator.kind == kind {
			return punctuator.text
		}
	}
	unreachable()
}

// quoted puts text in backticks, the way messages show code.
@(private)
quoted :: proc(p: ^Parser, text: string) -> string {
	return strings.concatenate({"`", text, "`"}, p.allocator)
}

// Statements end.

// end_statement consumes the `;` that ends a statement, or accepts its absence where automatic
// semicolon insertion puts one. Otherwise it reports the `;` missing and skips to the next
// statement.
@(private)
end_statement :: proc(p: ^Parser) {
	if accept(p, .Semicolon) {
		return
	}
	token := peek(p)
	if token.kind == .Close_Brace || token.kind == .EOF || token.line_break_before {
		return
	}
	error_expected(p, "`;`")
	skip_statement(p)
}

// skip_statement skips the rest of a broken statement: past the next `;`, or up to a closing
// bracket of an enclosing construct, a token on a new line that starts a statement, or the end.
// Brackets opened in between are skipped whole.
@(private)
skip_statement :: proc(p: ^Parser) {
	for {
		token := peek(p)
		#partial switch token.kind {
		case .EOF, .Close_Paren, .Close_Bracket, .Close_Brace, .Template_Middle, .Template_Tail:
			return
		case .Semicolon:
			advance(p)
			return
		case .Open_Paren, .Open_Bracket, .Open_Brace, .Template_Head:
			skip_balanced(p)
			continue
		}
		if token.line_break_before && starts_statement(token.kind) {
			return
		}
		advance(p)
	}
}

// skip_unsupported_member reports a member of an object type that is outside the subset, at span,
// and skips it. The result is NO_NODE: the member is left out of its list.
@(private)
skip_unsupported_member :: proc(
	p: ^Parser,
	construct: diag.Construct,
	span: source.Span,
) -> ast.Node_ID {
	report_unsupported(p, construct, span)
	skip_member(p)
	return ast.NO_NODE
}

// skip_member skips the rest of a member of an object type: up to the `,` or `;` after it, a line
// break or the closing `}`. Brackets are skipped whole.
@(private)
skip_member :: proc(p: ^Parser) {
	first := p.current
	for {
		token := peek(p)
		#partial switch token.kind {
		case .Comma, .Semicolon, .Close_Brace, .EOF:
			return
		case .Open_Paren, .Open_Bracket, .Open_Brace, .Template_Head:
			skip_balanced(p)
			continue
		}
		if token.line_break_before && p.current > first {
			return
		}
		advance(p)
	}
}

// starts_statement reports the keywords that start a statement, where skip_statement stops.
@(private)
starts_statement :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Let,
	     .Const,
	     .Var,
	     .Function,
	     .Class,
	     .Enum,
	     .Interface,
	     .If,
	     .For,
	     .While,
	     .Do,
	     .Switch,
	     .Return,
	     .Break,
	     .Continue,
	     .Import,
	     .Export,
	     .Try,
	     .Throw,
	     .With:
		return true
	}
	return false
}
