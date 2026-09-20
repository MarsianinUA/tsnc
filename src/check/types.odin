/*
The TypeScript types of one check and the table that holds them.

Interning: every type goes into the table once, so one structure has one Type_ID and type identity
is `==` on the id. The types with no parts are interned first, in the order of Basic_Kind, so ERROR
is row 0 of every table. A parameter name is not part of a function type, as it is not in
TypeScript, so two signatures that differ only in their names share one id and print with the names
of whichever one arrived first.

The error type: the type of a node that failed. It is assignable in both directions, so one mistake
produces one diagnostic and not a line of them.

Canonical order: the members of a union are sorted by structure, never by Type_ID. Type_ID values
follow the order one checker happened to intern things in, while the printed type reaches the user;
sorting by structure is what makes two checkers over two partitions spell one union the same way,
whatever `-j` says.

Memory: a type and its parts come from the allocator the table was made with, which is meant to be
an arena; the table never frees. Interning keys, and the parts of a type that turns out to be in the
table already, are built in context.temp_allocator.
*/
package check

import "base:runtime"
import "core:slice"
import "core:strings"

import "../ast"

// Type_ID indexes the type table of one Check_Result. It means nothing without that table.
Type_ID :: distinct u32

// The types with no parts, interned first and in this order by make_table, so they are constants
// rather than lookups. ERROR is zero, as ast.NO_NODE and bind.NO_SYMBOL are.
ERROR :: Type_ID(Basic_Kind.Error)
ANY :: Type_ID(Basic_Kind.Any)
UNKNOWN :: Type_ID(Basic_Kind.Unknown)
NEVER :: Type_ID(Basic_Kind.Never)
BOOLEAN :: Type_ID(Basic_Kind.Boolean)
NUMBER :: Type_ID(Basic_Kind.Number)
STRING :: Type_ID(Basic_Kind.String)
VOID :: Type_ID(Basic_Kind.Void)
NULL :: Type_ID(Basic_Kind.Null)
UNDEFINED :: Type_ID(Basic_Kind.Undefined)

// Type is one TypeScript type. lower reads it as a value: the parameters and the result of a
// function, the members of a union in canonical order.
Type :: union #no_nil {
	Basic_Kind, // a zero Type is Basic_Kind.Error, the type of a node that failed
	Literal,
	Function,
	Union,
}

// Basic_Kind is a type with no parts. The order is the first half of the canonical order of a
// union, so it is also the order these are interned in. `void`, `null` and `undefined` come last
// because that is where a union reads best and where TypeScript itself puts them: `string |
// undefined`, not the other way round.
Basic_Kind :: enum u8 {
	Error,
	Any,
	Unknown,
	Never,
	Boolean,
	Number,
	String,
	Void,
	Null,
	Undefined,
}

// Literal is a value used as a type: `42`, `"circle"`, `true`. It holds the value the way ast does,
// so a literal expression and a literal type read the same.
Literal :: struct {
	value: ast.Literal,
}

Function :: struct {
	params:   []Param, // in source order
	result:   Type_ID,
	required: int, // a call has to supply this many; the rest are optional or the rest parameter
	variadic: bool, // the last parameter is `...xs: T[]`, so a call may pass any number past it
}

// Param is one parameter of a function type. The name is borrowed from the tree and is printed in a
// diagnostic; it takes no part in type identity.
Param :: struct {
	name: string,
	type: Type_ID,
}

// Union holds two or more members, in canonical order, with no duplicates and never a union among
// them. A union of one member is that member, and a union of none is `never`.
Union :: struct {
	members: []Type_ID,
}

// Table is the type universe of one check call. It is not part of the result: Check_Result carries
// the frozen rows alone, because a caller reads types and never makes them.
@(private)
Table :: struct {
	allocator: runtime.Allocator,
	types:     [dynamic]Type,
	// The interned types by canonical key. It is only ever read by key: Odin's map iteration order
	// changes between runs, so nothing whose order reaches the output may come out of a map.
	by_key:    map[string]Type_ID,
	// The buffer intern builds the key of one type in. Nothing interns while a key is being built,
	// so one buffer serves every call, and a probe lives only until the next one.
	key:       strings.Builder,
}

// make_table interns the types with no parts, in the order of Basic_Kind, which is what makes every
// one of the constants above its own row number.
@(private)
make_table :: proc(allocator: runtime.Allocator) -> Table {
	table := Table {
		allocator = allocator,
		types     = make([dynamic]Type, 0, 64, allocator),
		by_key    = make(map[string]Type_ID, allocator),
		key       = strings.builder_make(context.temp_allocator),
	}
	for kind in Basic_Kind {
		id := intern(&table, kind)
		assert(id == Type_ID(kind), "the types with no parts are the first rows of the table")
	}
	return table
}

// Making types.

// literal_type is the type of one literal value. A negative zero is folded into zero: parse reads
// the minus of `-0` into the value, while TypeScript has one literal type for both and `-0 === 0`
// at run time.
@(private)
literal_type :: proc(table: ^Table, value: ast.Literal) -> Type_ID {
	value := value
	if number, is_number := value.(f64); is_number && number == 0 {
		value = f64(0)
	}
	return intern(table, Literal{value = value})
}

// function_type is the type of a function, an arrow or a function type. params may be scratch:
// intern copies what it keeps.
@(private)
function_type :: proc(
	table: ^Table,
	params: []Param,
	result: Type_ID,
	required: int,
	variadic: bool,
) -> Type_ID {
	function := Function {
		params   = params,
		result   = result,
		required = required,
		variadic = variadic,
	}
	return intern(table, function)
}

// union_type is the canonical union of members: every union among them is flattened into its own
// members, duplicates are dropped, `never` adds nothing, and the rest end up in canonical order.
// One member is that member, and none at all is `never`.
//
// `any` and the error type swallow a union: a value that may be anything is not better described by
// listing some of it, and a union built on a type that already failed would report the failure
// again at every use.
@(private)
union_type :: proc(table: ^Table, members: []Type_ID) -> Type_ID {
	for member in members {
		if member == ERROR || member == ANY {
			return member
		}
	}

	out := make([dynamic]Type_ID, 0, len(members), context.temp_allocator)
	for member in members {
		add_member(table, &out, member)
	}
	reduce_members(table, &out)

	switch len(out) {
	case 0:
		return NEVER
	case 1:
		return out[0]
	}
	return intern(table, Union{members = out[:]})
}

// reduce_members drops a member that another one already covers: `number | 1` is `number`, since
// every `1` is a number. `true | false` goes the other way, because the two of them together are
// every boolean there is, and that is how TypeScript writes the pair.
@(private)
reduce_members :: proc(table: ^Table, members: ^[dynamic]Type_ID) {
	both_booleans := has_boolean(table, members[:], true) && has_boolean(table, members[:], false)

	// The test reads the list while the loop writes it, so it reads a copy instead.
	before := make([]Type_ID, len(members), context.temp_allocator)
	copy(before, members[:])

	kept := 0
	for member in before {
		literal, is_literal := table.types[member].(Literal)
		if is_literal {
			base := literal_base(literal.value)
			covered := slice.contains(before, base) || (base == BOOLEAN && both_booleans)
			if covered {
				continue
			}
		}
		members[kept] = member
		kept += 1
	}
	resize(members, kept)

	if both_booleans {
		add_member(table, members, BOOLEAN)
	}
}

@(private)
has_boolean :: proc(table: ^Table, members: []Type_ID, want: bool) -> bool {
	for member in members {
		literal, is_literal := table.types[member].(Literal)
		if !is_literal {
			continue
		}
		if value, is_bool := literal.value.(bool); is_bool && value == want {
			return true
		}
	}
	return false
}

// add_member puts one member into a union under construction, where the canonical order puts it. A
// union has a handful of members at most, so inserting in place keeps this a plain loop and needs
// no comparator that carries the table with it.
@(private)
add_member :: proc(table: ^Table, out: ^[dynamic]Type_ID, member: Type_ID) {
	if nested, is_union := table.types[member].(Union); is_union {
		for inner in nested.members {
			add_member(table, out, inner)
		}
		return
	}
	if member == NEVER {
		return // `never` has no values, so it adds none to a union
	}

	for existing, i in out {
		order := compare_types(table.types[:], member, existing)
		if order == 0 {
			return
		}
		if order < 0 {
			inject_at(out, i, member)
			return
		}
	}
	append(out, member)
}

// intern is the one way a type enters the table. The parts of `type` may be scratch: a type that is
// already there is found by its key alone, and only a new one copies its parts into the table's
// allocator.
@(private)
intern :: proc(table: ^Table, type: Type) -> Type_ID {
	strings.builder_reset(&table.key)
	write_key(&table.key, type)
	probe := strings.to_string(table.key)
	if id, found := table.by_key[probe]; found {
		return id
	}

	owned := type
	switch v in type {
	case Basic_Kind, Literal:
	// No parts to copy.
	case Function:
		owned = Function {
			params   = clone_params(v.params, table.allocator),
			result   = v.result,
			required = v.required,
			variadic = v.variadic,
		}
	case Union:
		members := make([]Type_ID, len(v.members), table.allocator)
		copy(members, v.members)
		owned = Union {
			members = members,
		}
	}

	id := Type_ID(len(table.types))
	append(&table.types, owned)
	table.by_key[strings.clone(probe, table.allocator)] = id
	return id
}

@(private)
clone_params :: proc(params: []Param, allocator: runtime.Allocator) -> []Param {
	owned := make([]Param, len(params), allocator)
	copy(owned, params)
	return owned
}

// write_key writes the key a type is interned under. It is built from the Type_ID values of the
// parts, which are interned already, so it stays short and it always terminates, even once a type
// can name itself. A parameter name is left out, because it is not part of the type. The key is
// internal: it is never printed and never ordered.
@(private)
write_key :: proc(b: ^strings.Builder, type: Type) {
	switch v in type {
	case Basic_Kind:
		strings.write_string(b, "b")
		strings.write_int(b, int(v))
	case Literal:
		switch value in v.value {
		case bool:
			strings.write_string(b, "lb" if value else "lB")
		case f64:
			strings.write_string(b, "ln")
			strings.write_u64(b, transmute(u64)value, 16)
		case string:
			strings.write_string(b, "ls")
			strings.write_quoted_string(b, value)
		}
	case Function:
		strings.write_string(b, "f")
		strings.write_int(b, v.required)
		strings.write_string(b, "v" if v.variadic else "-")
		for param in v.params {
			strings.write_byte(b, ',')
			strings.write_u64(b, u64(param.type))
		}
		strings.write_byte(b, '>')
		strings.write_u64(b, u64(v.result))
	case Union:
		strings.write_string(b, "u")
		for member in v.members {
			strings.write_byte(b, ',')
			strings.write_u64(b, u64(member))
		}
	}
}

// Canonical order.

// compare_types orders two types by structure: negative when a comes first, zero when they are one
// type. It reads no Type_ID as a number, so two checkers that built one union independently sort it
// the same way. It recurses only into the parts of a type, and no type of this milestone can hold
// itself, so it terminates.
@(private)
compare_types :: proc(types: []Type, a, b: Type_ID) -> int {
	if a == b {
		return 0
	}

	left, right := types[a], types[b]
	if rank(left) != rank(right) {
		return -1 if rank(left) < rank(right) else 1
	}

	#partial switch v in left {
	case Literal:
		return compare_literals(v.value, right.(Literal).value)
	case Function:
		return compare_functions(types, v, right.(Function))
	case Union:
		return compare_members(types, v.members, right.(Union).members)
	}
	// Two types with no parts and one rank are one type, which the first line already answered.
	return 0
}

// rank is where a kind of type stands in the canonical order: the kinds with no parts first, in the
// order of Basic_Kind, then the literals, then functions, then unions.
@(private)
rank :: proc(type: Type) -> int {
	BASIC :: len(Basic_Kind)
	switch v in type {
	case Basic_Kind:
		return int(v)
	case Literal:
		return BASIC + literal_rank(v.value)
	case Function:
		return BASIC + 3
	case Union:
		return BASIC + 4
	}
	return 0
}

@(private)
literal_rank :: proc(value: ast.Literal) -> int {
	switch _ in value {
	case bool:
		return 0
	case f64:
		return 1
	case string:
		return 2
	}
	return 0
}

@(private)
compare_literals :: proc(a, b: ast.Literal) -> int {
	switch left in a {
	case bool:
		right := b.(bool)
		if left == right {
			return 0
		}
		return -1 if !left else 1
	case f64:
		right := b.(f64)
		if left == right {
			return 0
		}
		return -1 if left < right else 1
	case string:
		return strings.compare(left, b.(string))
	}
	return 0
}

@(private)
compare_functions :: proc(types: []Type, a, b: Function) -> int {
	if len(a.params) != len(b.params) {
		return -1 if len(a.params) < len(b.params) else 1
	}
	if a.required != b.required {
		return -1 if a.required < b.required else 1
	}
	if a.variadic != b.variadic {
		return -1 if !a.variadic else 1
	}
	for param, i in a.params {
		if order := compare_types(types, param.type, b.params[i].type); order != 0 {
			return order
		}
	}
	return compare_types(types, a.result, b.result)
}

@(private)
compare_members :: proc(types: []Type, a, b: []Type_ID) -> int {
	if len(a) != len(b) {
		return -1 if len(a) < len(b) else 1
	}
	for member, i in a {
		if order := compare_types(types, member, b[i]); order != 0 {
			return order
		}
	}
	return 0
}

// Reading types.

// literal_base is the type a literal type is one value of.
@(private)
literal_base :: proc(value: ast.Literal) -> Type_ID {
	switch _ in value {
	case bool:
		return BOOLEAN
	case f64:
		return NUMBER
	case string:
		return STRING
	}
	return ERROR
}

// widen is the type an inferred binding gets when the value it holds may change to another one of
// its kind: a literal type stands for its base. A `const` keeps its literal type, so the caller
// decides whether to widen at all.
@(private)
widen :: proc(table: ^Table, id: Type_ID) -> Type_ID {
	switch v in table.types[id] {
	case Basic_Kind, Function:
		return id
	case Literal:
		return literal_base(v.value)
	case Union:
		widened := make([dynamic]Type_ID, 0, len(v.members), context.temp_allocator)
		for member in v.members {
			append(&widened, widen(table, member))
		}
		return union_type(table, widened[:])
	}
	return id
}

// Part names what is left of a type once a test on it has gone one way. `a && b` keeps the falsy
// part of a, `a || b` the truthy part, and `a ?? b` the part that is neither null nor undefined.
@(private)
Part :: enum u8 {
	Falsy,
	Truthy,
	Not_Nullish,
}

// part_of is what survives that test. Keeping only the surviving part is what makes
// `name || "none"` a `string` where name is `string | undefined`: tsc types it the same way, and
// the differential gate of T4.7 runs `tsc --strict` over every program first.
//
// A member of a union that survives nothing comes back as `never`, and union_type then drops it,
// which is how `string | undefined` loses its `undefined`.
@(private)
part_of :: proc(table: ^Table, id: Type_ID, part: Part) -> Type_ID {
	switch v in table.types[id] {
	case Basic_Kind:
		#partial switch v {
		case .Null, .Undefined, .Void:
			// All three are falsy, and the first two are the pair `??` asks about.
			return id if part == .Falsy else NEVER
		case .Boolean:
			return literal_type(table, false) if part == .Falsy else id
		case .Number:
			return literal_type(table, f64(0)) if part == .Falsy else id
		case .String:
			return literal_type(table, "") if part == .Falsy else id
		case .Any, .Unknown, .Error:
			return id
		}
		return NEVER // `never` has no values, so no part of it survives anything
	case Literal:
		if part == .Not_Nullish {
			return id // a literal is a number, a string or a boolean, never null or undefined
		}
		falsy := is_falsy(v.value)
		return id if falsy == (part == .Falsy) else NEVER
	case Function:
		return NEVER if part == .Falsy else id // a function value is always truthy
	case Union:
		out := make([dynamic]Type_ID, 0, len(v.members), context.temp_allocator)
		for member in v.members {
			append(&out, part_of(table, member, part))
		}
		return union_type(table, out[:])
	}
	return id
}

@(private)
is_falsy :: proc(value: ast.Literal) -> bool {
	switch v in value {
	case bool:
		return !v
	case f64:
		return v == 0
	case string:
		return v == ""
	}
	return false
}

// assignable reports whether a value of `source` may stand where `target` is expected.
@(private)
assignable :: proc(types: []Type, source, target: Type_ID) -> bool {
	if source == target {
		return true
	}
	// The error type has had its diagnostic already, and `any` is the type that gives up on
	// checking. Letting both pass in either direction keeps one mistake from becoming many.
	if source == ERROR || target == ERROR || source == ANY || target == ANY {
		return true
	}
	// `never` is the type with no values, so nothing can go wrong; `unknown` is the type that
	// promises nothing, so anything fits it.
	if source == NEVER || target == UNKNOWN {
		return true
	}
	// A function that runs off its end returns `undefined`, and `void` is how TypeScript writes a
	// result no caller reads.
	if source == UNDEFINED && target == VOID {
		return true
	}

	if literal, is_literal := types[source].(Literal); is_literal {
		if literal_base(literal.value) == target {
			return true
		}
	}

	// A union fits where every one of its members fits.
	if members, is_union := types[source].(Union); is_union {
		for member in members.members {
			if !assignable(types, member, target) {
				return false
			}
		}
		return true
	}
	// A value fits a union when it fits one of the members.
	if members, is_union := types[target].(Union); is_union {
		for member in members.members {
			if assignable(types, source, member) {
				return true
			}
		}
		return false
	}

	source_function, source_is_function := types[source].(Function)
	target_function, target_is_function := types[target].(Function)
	if source_is_function && target_is_function {
		return function_assignable(types, source_function, target_function)
	}
	return false
}

// function_assignable is the rule for a function value: every call the target allows has to be a
// call the source accepts. So the source may ask for fewer arguments but never for more, each
// parameter is compared the other way round, and the result has to fit unless the target throws it
// away.
@(private)
function_assignable :: proc(types: []Type, source, target: Function) -> bool {
	if !target.variadic && source.required > len(target.params) {
		return false
	}
	shared := min(len(source.params), len(target.params))
	for i in 0 ..< shared {
		if !assignable(types, target.params[i].type, source.params[i].type) {
			return false
		}
	}
	if target.result == VOID {
		return true
	}
	return assignable(types, source.result, target.result)
}

// Printing a type.

// type_text is how a type reads: `number`, `"circle"`, `(a: number) => string`, `number | string`.
// types is the table the id belongs to, which is Check_Result.types.
//
// Inside check it is called with the checker's allocator, because a diagnostic borrows its
// arguments and is rendered long after the phase has returned.
type_text :: proc(types: []Type, id: Type_ID, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_type(&b, types, id)
	return strings.to_string(b)
}

@(private)
write_type :: proc(b: ^strings.Builder, types: []Type, id: Type_ID) {
	switch v in types[id] {
	case Basic_Kind:
		strings.write_string(b, BASIC_TEXTS[v])
	case Literal:
		switch value in v.value {
		case bool:
			strings.write_string(b, "true" if value else "false")
		case f64:
			write_number(b, value)
		case string:
			strings.write_quoted_string(b, value)
		}
	case Function:
		write_function(b, types, v)
	case Union:
		for member, i in v.members {
			if i > 0 {
				strings.write_string(b, " | ")
			}
			// A function inside a union needs brackets, or the `|` would read as part of its result.
			_, is_function := types[member].(Function)
			if is_function {
				strings.write_byte(b, '(')
			}
			write_type(b, types, member)
			if is_function {
				strings.write_byte(b, ')')
			}
		}
	}
}

@(private)
write_function :: proc(b: ^strings.Builder, types: []Type, function: Function) {
	strings.write_byte(b, '(')
	for param, i in function.params {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		is_rest := function.variadic && i == len(function.params) - 1
		if is_rest {
			strings.write_string(b, "...")
		}
		strings.write_string(b, param.name)
		if !is_rest && i >= function.required {
			strings.write_byte(b, '?')
		}
		strings.write_string(b, ": ")
		write_type(b, types, param.type)
	}
	strings.write_string(b, ") => ")
	write_type(b, types, function.result)
}

// write_number prints the value of a number literal type. strings.write_float drops the `+` that
// strconv writes for a positive number, which no TypeScript type ever shows.
//
// Where this differs from the program it compiles: the ECMAScript `Number::toString` rules of
// requirements 3.1, with their 1e21 and 1e-7 thresholds, belong to the runtime and arrive in T4.6.
// A diagnostic is read by a person, not compared with Node, so the shortest decimal form does.
@(private)
write_number :: proc(b: ^strings.Builder, value: f64) {
	strings.write_float(b, value, 'f', -1, 64)
}

@(private, rodata)
BASIC_TEXTS := [Basic_Kind]string {
	.Error     = "?",
	.Any       = "any",
	.Unknown   = "unknown",
	.Never     = "never",
	.Void      = "void",
	.Null      = "null",
	.Undefined = "undefined",
	.Boolean   = "boolean",
	.Number    = "number",
	.String    = "string",
}
