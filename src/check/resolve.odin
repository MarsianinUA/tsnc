package check

import "base:runtime"
import "core:slice"

import "../ast"
import "../bind"
import "../diag"
import "../program"
import "../source"

@(private)
resolve_type :: proc(c: ^Checker, id: ast.Node_ID) -> Type_ID {
	if id == ast.NO_NODE {
		return ERROR
	}
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Keyword_Type:
		return set_type(c, id, KEYWORD_TYPES[v.keyword])
	case ast.Literal_Type:
		return set_type(c, id, literal_type(&c.table, v.value))
	case ast.Union_Type:
		members := make([dynamic]Type_ID, 0, len(v.members), context.temp_allocator)
		for member in v.members {
			append(&members, resolve_type(c, member))
		}
		return set_type(c, id, union_type(&c.table, members[:]))
	case ast.Function_Type:
		check_signature_type_params(c, v.type_params)
		type_params := resolve_type_params(c, v.type_params)
		params, required, variadic := resolve_params(c, v.params)
		result := resolve_type(c, v.return_type)
		type := function_type(&c.table, params, result, required, variadic, type_params)
		return set_type(c, id, type)
	case ast.Array_Type:
		return set_type(c, id, array_type(&c.table, resolve_type(c, v.element)))
	case ast.Object_Type:
		return set_type(c, id, plain_object_type(&c.table, object_fields(c, v.members)))
	case ast.Type_Ref:
		return set_type(c, id, type_ref_type(c, id, v))
	}
	return set_type(c, id, ERROR)
}

// resolve_type_params answers only in the lib file, which alone declares type variables: a type
// parameter of a user file answers with the error type, and a signature that holds none is the
// ordinary case.
@(private)
resolve_type_params :: proc(c: ^Checker, ids: []ast.Node_ID) -> []Type_ID {
	if len(ids) == 0 || c.at.file != program.LIB {
		return nil
	}
	out := make([dynamic]Type_ID, 0, len(ids), context.temp_allocator)
	for id in ids {
		type_param := c.at.tree.nodes[id].variant.(ast.Type_Param)
		decl := Decl_Ref {
			file = c.at.file,
			node = id,
		}
		append(&out, type_var_type(&c.table, type_param.name.text, decl))
	}
	return out[:]
}

@(private, rodata)
KEYWORD_TYPES := [ast.Type_Keyword]Type_ID {
	.Number    = NUMBER,
	.String    = STRING,
	.Boolean   = BOOLEAN,
	.Null      = NULL,
	.Undefined = UNDEFINED,
	.Void      = VOID,
	.Any       = ANY,
	.Unknown   = UNKNOWN,
	.Never     = NEVER,
}

// resolve_params counts in required the parameters a call has to supply, which is the run of
// required ones at the front: a required parameter behind an optional one is a signature tsc
// rejects, and tsnc takes its input from tsc.
//
// contextual is the signature an arrow is going into, and gives a parameter with no annotation its
// type. parameter_at answers for the position, so one landing on an optional parameter is
// `T | undefined` and one landing on a rest parameter is the element type: what a call can really
// leave there. Everywhere else there is no signature, and a parameter with no annotation is a name
// nothing can check.
@(private)
resolve_params :: proc(
	c: ^Checker,
	ids: []ast.Node_ID,
	contextual: Maybe(Function) = nil,
) -> (
	params: []Param,
	required: int,
	variadic: bool,
) {
	out := make([dynamic]Param, 0, len(ids), context.temp_allocator)
	for id, i in ids {
		param := c.at.tree.nodes[id].variant.(ast.Param)
		type := ERROR
		switch {
		case param.type != ast.NO_NODE:
			type = resolve_type(c, param.type)
		case contextual != nil:
			// Past the end of a signature with no rest parameter there is no context at all.
			type = parameter_at(c, contextual.?, i)
			if type == ERROR {
				report(c, .Missing_Annotation, param.name.span, param.name.text)
			}
		case:
			report(c, .Missing_Annotation, param.name.span, param.name.text)
		}

		// The body sees what a call can actually leave there, while the signature keeps the type as
		// it was written: TypeScript prints `b?: string`, not `b?: string | undefined`.
		inside := type
		switch param.kind {
		case .Required:
			if required == i {
				required += 1
			}
		case .Optional:
			inside = union_of(c, type, UNDEFINED)
		case .Rest:
			variadic = true
		}

		set_type(c, id, inside)
		append(&out, Param{name = param.name.text, type = type})
	}
	return out[:], required, variadic
}

// resolve_name stays inside this file: bind answers for a name the file declares, an import
// included; a name it does not is a name of the lib module, which every file sees, or nothing at
// all. Following an import to the module it came from is modules.odin's job.
@(private)
resolve_name :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	name: string,
	meaning: bind.Meaning,
) -> Symbol_Ref {
	if symbol := c.at.bound.node_symbols[id]; symbol != bind.NO_SYMBOL {
		return {file = c.at.file, symbol = symbol}
	}
	lib := c.program.bound[program.LIB]
	if symbol := bind.lookup(lib, bind.MODULE_SCOPE, name, meaning); symbol != bind.NO_SYMBOL {
		return {file = program.LIB, symbol = symbol}
	}
	return {}
}

// Search is Tarjan's walk over the declarations whose types are being worked out: the values of
// type_of_symbol and the aliases of alias_type. A declaration that needs its own type, through any
// number of others, closes a loop, and the loop is a strongly connected component of the walk: the
// same declarations whichever of them a checker asks for first. That is what gives one report per
// loop and the same types under every split of the program. A top-level statement that runs code
// has a frame too (walk_statement), since a read narrowed through it needs its facts.
@(private)
Search :: struct {
	frames:  [dynamic]Frame, // Tarjan's stack
	index:   map[Symbol_Ref]int, // the frame of a declaration still on the stack
	current: int, // the frame whose declaration is being read, -1 between searches
}

@(private)
Frame :: struct {
	ref:      Symbol_Ref, // NO_SYMBOL for a statement, which no cache holds and no report names
	low:      int, // the lowest frame this one reaches
	looped:   bool, // asked for again while on the stack
	recorded: Type_ID, // the type a declarator records before its initializer is read, or ERROR
	instance: bool, // an alias read with type arguments, which no cache holds
}

@(private)
make_search :: proc(allocator: runtime.Allocator) -> Search {
	return {
		frames = make([dynamic]Frame, allocator),
		index = make(map[Symbol_Ref]int, allocator),
		current = -1,
	}
}

// type_of_symbol answers from the cache, or works the type out in a frame of the search. A
// declaration asked for while its frame is on the stack answers what it recorded so far, ERROR if
// nothing, and joins the loop. A local with a recorded type does not join: it is reached only
// through the one body that declares it, in that body's order, while a module global may be
// reached first from anywhere.
@(private)
type_of_symbol :: proc(c: ^Checker, ref: Symbol_Ref) -> Type_ID {
	if ref.symbol == bind.NO_SYMBOL {
		return ERROR
	}
	if cached, found := c.symbol_types[ref]; found {
		return cached
	}
	symbol := c.program.bound[ref.file].symbols[ref.symbol]
	if at, open := c.search.index[ref]; open {
		recorded := c.search.frames[at].recorded
		if recorded == ERROR || symbol.scope == bind.MODULE_SCOPE {
			reached(c, at)
		}
		return recorded
	}

	at, outer := enter_frame(c, ref)
	previous := move_to(c, ref.file)
	type := leave_frame(c, at, outer, declared_type(c, ref, symbol))
	c.at = previous
	if outer < 0 {
		check_deferred(c)
	}
	return type
}

@(private)
enter_frame :: proc(c: ^Checker, ref: Symbol_Ref, instance := false) -> (at, outer: int) {
	at = len(c.search.frames)
	append(&c.search.frames, Frame{ref = ref, low = at, recorded = ERROR, instance = instance})
	if ref.symbol != bind.NO_SYMBOL {
		c.search.index[ref] = at
	}
	outer = c.search.current
	c.search.current = at
	return at, outer
}

// reached joins the frame being read to a declaration still on the stack: they are one loop.
@(private)
reached :: proc(c: ^Checker, at: int) {
	frames := c.search.frames[:]
	frames[at].looped = true
	frames[c.search.current].low = min(frames[c.search.current].low, at)
}

// leave_frame answers the type of the declaration the frame was for. Any member but the root of its
// component answers what it recorded, ERROR if nothing; the root closes the component.
@(private)
leave_frame :: proc(c: ^Checker, at, outer: int, type: Type_ID) -> Type_ID {
	frames := c.search.frames[:]
	c.search.current = outer
	if outer >= 0 {
		frames[outer].low = min(frames[outer].low, frames[at].low)
	}
	if frames[at].low != at {
		return frames[at].recorded
	}
	return close_component(c, at, type)
}

// close_component pops the component the frame at `at` is the root of, and caches the type of every
// member but an instance and a statement: its own where nothing looped. In a loop each member keeps
// what it recorded, and those that recorded nothing take ERROR, with one diagnostic at the one
// declared first. The answer is the root's. A statement is let go from Module_Walk.held.
@(private)
close_component :: proc(c: ^Checker, at: int, type: Type_ID) -> Type_ID {
	members := c.search.frames[at:]
	// Every member but the root joined the loop, so two members always are one.
	looped := len(members) > 1 || members[0].looped
	answer := members[0].recorded if looped else type
	first := -1
	for member, i in members {
		if member.ref.symbol == bind.NO_SYMBOL {
			c.walks[member.ref.file].held = false
			continue
		}
		delete_key(&c.search.index, member.ref)
		final := member.recorded if looped else type
		if looped &&
		   final == ERROR &&
		   (first < 0 || declared_before(c, member.ref, members[first].ref)) {
			first = i
		}
		if !member.instance {
			c.symbol_types[member.ref] = final
		}
	}
	if first >= 0 {
		report_loop(c, members[first].ref)
	}
	resize(&c.search.frames, at)
	return answer
}

// report_loop puts an alias loop past the quiet of an instance (report): the loop is the same
// whichever instance or plain read finds it first, and only one of them may be left to close it.
// Each instance of a loop of generic aliases closes it again, so it is reported once.
@(private)
report_loop :: proc(c: ^Checker, ref: Symbol_Ref) {
	symbol := c.program.bound[ref.file].symbols[ref.symbol]
	if symbol.kind == .Type_Alias {
		if !slice.contains(c.alias_loops[:], ref) {
			append(&c.alias_loops, ref)
			emit(c, .Circular_Type, symbol.name.span, symbol.name.text)
		}
		return
	}
	report(c, recursion_code(c, ref, symbol), symbol.name.span, symbol.name.text)
}

// Deferred is a body or an initializer whose type is written out, so nothing has to read it to type
// its declaration. check_deferred reads it once no search is open, so every name it uses is settled
// by then, in whatever order the declarations were met.
@(private)
Deferred :: struct {
	file:       source.File_ID,
	value:      ast.Node_ID, // a function body, or an initializer
	result:     Type_ID,
	annotation: ast.Node_ID, // the written result of a body; NO_NODE for an initializer
}

@(private)
defer_check :: proc(c: ^Checker, value: ast.Node_ID, result: Type_ID, annotation := ast.NO_NODE) {
	if value != ast.NO_NODE {
		append(&c.deferred, Deferred{c.at.file, value, result, annotation})
	}
}

// check_deferred may run again inside a body it reads, which then goes on with the next item: the
// order of the items changes no answer, since every name they read is settled.
@(private)
check_deferred :: proc(c: ^Checker) {
	for len(c.deferred) > 0 {
		item := pop_front(&c.deferred)
		previous := move_to(c, item.file)
		if item.annotation != ast.NO_NODE {
			check_body(c, item.value, item.result, nil)
			check_result_reached(c, item.value, item.annotation, item.result)
		} else {
			check_initializer(c, item.value, item.result)
		}
		c.at = previous
	}
}

@(private)
declared_before :: proc(c: ^Checker, a, b: Symbol_Ref) -> bool {
	if a.file != b.file {
		return a.file < b.file
	}
	declarations := c.program.bound[a.file].symbols
	return declarations[a.symbol].declaration < declarations[b.symbol].declaration
}

// recursion_code tells two mistakes apart: a function and an arrow both lack a result the search
// could use, which is what an annotation supplies; any other variable has an initializer that reads
// the name it is defining.
@(private)
recursion_code :: proc(c: ^Checker, ref: Symbol_Ref, symbol: bind.Symbol) -> diag.Code {
	if symbol.kind == .Function {
		return .Recursive_Return_Type
	}
	nodes := c.program.trees[ref.file].nodes
	if declarator, is_declarator := nodes[symbol.declaration].variant.(ast.Declarator);
	   is_declarator {
		if _, is_arrow := nodes[declarator.init].variant.(ast.Arrow); is_arrow {
			return .Recursive_Return_Type
		}
	}
	return .Circular_Initializer
}

@(private)
declared_type :: proc(c: ^Checker, ref: Symbol_Ref, symbol: bind.Symbol) -> Type_ID {
	node := symbol.declaration
	#partial switch v in c.at.tree.nodes[node].variant {
	case ast.Declarator:
		return declarator_type(c, node, v, symbol)
	case ast.Function_Decl:
		return function_decl_type(c, node, v)
	case ast.Param:
		// A parameter takes its type when its function is typed, which always happens before
		// anything in the body can name it.
		return c.at.node_types == nil ? ERROR : c.at.node_types[node]
	}
	// An interface, a type alias and a type parameter are types and not values, and named_type is
	// the path that answers for them. An alias does not arrive either: imported_name follows it to
	// the declaration behind it and asks about that.
	return ERROR
}

// declarator_type checks the initializer while it is here, unless the declarator writes its type
// and a read of the name cannot be narrowed by the initializer: then nothing needs the initializer
// to type the name, and it waits for check_deferred. An initializer that adds to the flow of its
// function never waits, since later reads are narrowed through it, and so a local's waits only when
// it is an arrow. The walk over the statements comes through here too, so this happens exactly
// once.
@(private)
declarator_type :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Declarator,
	symbol: bind.Symbol,
) -> Type_ID {
	arrow, is_arrow := c.at.tree.nodes[node.init].variant.(ast.Arrow)
	if node.type != ast.NO_NODE {
		declared := resolve_type(c, node.type)
		set_type(c, id, declared)
		c.search.frames[c.search.current].recorded = declared
		switch {
		case node.init == ast.NO_NODE:
			if symbol.kind == .Let && exported(c, id) && !fits(c, UNDEFINED, declared) {
				// No walk sees across modules, so a write in another one cannot be looked for.
				report(c, .Used_Before_Assigned, node.name.span, node.name.text)
			}
		case !narrows(c, declared) &&
		     (is_arrow || symbol.scope == bind.MODULE_SCOPE && !adds_flow(c, node.init)):
			defer_check(c, node.init, declared)
		case:
			check_initializer(c, node.init, declared)
		}
		return declared
	}

	if node.init == ast.NO_NODE {
		// Requirements 5 takes a variable's type from its initializer, and there is none.
		report(c, .Missing_Annotation, node.name.span, node.name.text)
		return set_type(c, id, ERROR)
	}

	if is_arrow && arrow.return_type != ast.NO_NODE && !is_open_arrow(c, node.init) {
		type := written_signature(c, arrow.params, arrow.return_type, arrow.body)
		set_type(c, node.init, type)
		return set_type(c, id, type)
	}

	value := check_expression(c, node.init)
	// A `const` keeps the literal type of its value, because the binding never takes another one.
	// A `let` widens, because it can.
	return set_type(c, id, value if symbol.kind == .Const else widen(&c.table, value))
}

// adds_flow says whether an expression adds to the flow of its function, which a later read is
// narrowed through: an assignment, or a branch of `&&`, `||`, `??` or `?:`. An arrow's body is a
// flow of its own.
@(private)
adds_flow :: proc(c: ^Checker, root: ast.Node_ID) -> bool {
	stack := make([dynamic]ast.Node_ID, context.temp_allocator)
	append(&stack, root)
	for {
		popped := len(stack) - 1
		id := ast.walk(c.at.tree.nodes, &stack) or_break
		#partial switch v in c.at.tree.nodes[id].variant {
		case ast.Assign, ast.Update, ast.Conditional:
			return true
		case ast.Binary:
			if v.op == .And || v.op == .Or || v.op == .Coalesce {
				return true
			}
		case ast.Arrow:
			resize(&stack, popped)
		}
	}
	return false
}

@(private)
check_initializer :: proc(c: ^Checker, init: ast.Node_ID, declared: Type_ID) {
	value := check_expression(c, init, declared)
	if !fits(c, value, declared) {
		report_assign_failure(c, span_of(c, init), value, declared)
	}
}

// written_signature types a function whose result is written out, and leaves its body for
// check_deferred: a caller needs the signature and nothing else.
@(private)
written_signature :: proc(
	c: ^Checker,
	params: []ast.Node_ID,
	annotation, body: ast.Node_ID,
) -> Type_ID {
	types, required, variadic := resolve_params(c, params)
	result := resolve_type(c, annotation)
	defer_check(c, body, result, annotation)
	return function_type(&c.table, types, result, required, variadic)
}

@(private)
exported :: proc(c: ^Checker, declaration: ast.Node_ID) -> bool {
	symbol := c.at.bound.node_symbols[declaration]
	if symbol == bind.NO_SYMBOL {
		return false
	}
	for export in c.at.bound.exports {
		if export.symbol == symbol {
			return true
		}
	}
	return false
}

// function_decl_type reads the body while it is here when the result is inferred from it. A body
// that calls the function itself then has nothing to find, which is what Recursive_Return_Type
// says.
@(private)
function_decl_type :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Function_Decl) -> Type_ID {
	if node.return_type != ast.NO_NODE {
		return set_type(c, id, written_signature(c, node.params, node.return_type, node.body))
	}

	params, required, variadic := resolve_params(c, node.params)
	returns := make([dynamic]Type_ID, 0, 4, context.temp_allocator)
	check_body(c, node.body, ERROR, &returns)
	result := inferred_result(c, node.body, returns[:])
	return set_type(c, id, function_type(&c.table, params, result, required, variadic))
}

// check_result_reached lets `void` and `any` take a body that can end without a `return`, and a
// result written `T | undefined` as well; anything else would hand the caller a value that is not
// there.
@(private)
check_result_reached :: proc(
	c: ^Checker,
	body: ast.Node_ID,
	annotation: ast.Node_ID,
	result: Type_ID,
) {
	if !falls_through(c, body) || fits(c, UNDEFINED, result) {
		return
	}
	report(c, .Missing_Return, span_of(c, annotation), text_of(c, result))
}

// inferred_result widens what the `return` statements gave, because what a call hands back is not
// the one literal the body happened to write.
//
// A body whose every `return` is bare gives `void`, as in tsc. One that mixes a bare `return` with
// a `return` of a value gives `undefined` for the bare one, which is what check_return's VOID
// marker says; and a body that can also run off its end gives `undefined` besides, which is what
// tsc infers for `function f(c: boolean) { if (c) return 1; }`.
@(private)
inferred_result :: proc(c: ^Checker, body: ast.Node_ID, returns: []Type_ID) -> Type_ID {
	if len(returns) == 0 || every_return_is_bare(returns) {
		return VOID
	}

	widened := make([dynamic]Type_ID, 0, len(returns) + 1, context.temp_allocator)
	for type in returns {
		append(&widened, UNDEFINED if type == VOID else widen(&c.table, type))
	}
	if falls_through(c, body) {
		append(&widened, UNDEFINED)
	}
	return union_type(&c.table, widened[:])
}

@(private)
every_return_is_bare :: proc(returns: []Type_ID) -> bool {
	for type in returns {
		if type != VOID {
			return false
		}
	}
	return true
}

// falls_through asks the flow graph. The flow at the end of a block is where the paths through it
// join, and a join is a node whether or not anything arrives, so reaches_start walks back from it
// and stops at a `return`, at a call that never returns and at an exhausted `switch`. An arrow
// written without braces is its own value and always produces one.
@(private)
falls_through :: proc(c: ^Checker, body: ast.Node_ID) -> bool {
	if body == ast.NO_NODE {
		return false
	}
	if _, is_block := c.at.tree.nodes[body].variant.(ast.Block); !is_block {
		return false
	}
	return reaches_start(c, c.at.bound.node_flow[body])
}

// check_body takes a non-nil returns while the result is being inferred, and collects in it what
// each `return` gave; otherwise result is the declared one and every `return` is checked against
// it.
@(private)
check_body :: proc(c: ^Checker, body: ast.Node_ID, result: Type_ID, returns: ^[dynamic]Type_ID) {
	if body == ast.NO_NODE {
		return // `declare function` has no body
	}

	previous_result, previous_returns := c.at.result, c.at.returns
	c.at.result, c.at.returns = result, returns
	defer {
		c.at.result = previous_result
		c.at.returns = previous_returns
	}

	if block, is_block := c.at.tree.nodes[body].variant.(ast.Block); is_block {
		check_statements(c, block.statements)
		set_type(c, body, VOID)
		return
	}

	// An arrow with no braces returns the expression it is.
	type := check_expression(c, body, result)
	if returns != nil {
		append(returns, type)
		return
	}
	if !fits(c, type, result) {
		report_assign_failure(c, span_of(c, body), type, result)
	}
}
