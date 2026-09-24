/*
The TypeScript types of one check and the table that holds them.

Interning: every type goes into the table once, so one structure has one Type_ID and type identity
is `==` on the id. The types with no parts are interned first, in the order of Basic_Kind, so ERROR
is row 0 of every table. A parameter name is not part of a function type, as it is not in
TypeScript, so two signatures that differ only in their names share one id and print with the names
of whichever one arrived first.

Named objects: an `interface` is interned by its declaration rather than by its shape, because
`interface Node { next: Node | undefined }` cannot have its members interned before itself. Its row
is reserved first and filled once the members are read, so a member that names the object again
finds the reserved row. Point and Vec2 with the same fields are therefore two ids that fit each
other in both directions, not one id. An object type written out in place has no declaration and is
interned by its fields, as every other type is.

The error type: the type of a node that failed. It is assignable in both directions, so one mistake
produces one diagnostic and not a line of them.

Canonical order: the members of a union are sorted by structure, never by Type_ID. Type_ID values
follow the order one checker happened to intern things in, while the printed type reaches the user;
sorting by structure is what makes two checkers over two partitions spell one union the same way,
whatever `-j` says. A named object is the one type that cannot be ordered by structure alone, since
it may hold itself, and since its fields are not all read yet while it is being reserved; it is
ordered by the declaration it came from, which is a fact of the Program and so reads the same in
every partition.

Memory: a type and its parts come from the allocator the table was made with, which is meant to be
an arena; the table never frees. Interning keys, and the parts of a type that turns out to be in the
table already, are built in context.temp_allocator.
*/
package check

import "base:runtime"
import "core:slice"
import "core:strings"

import "../ast"
import "../source"

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

// Type is what lower reads as a value: the parameters and the result of a function, the members of
// a union in canonical order, the fields of an object in canonical order.
Type :: union #no_nil {
	Basic_Kind, // a zero Type is Basic_Kind.Error, the type of a node that failed
	Literal,
	Function,
	Union,
	Object,
	Array,
	Type_Var,
	Overload,
}

// Basic_Kind lists the types with no parts in the first half of the canonical order of a union, so
// it is also the order these are interned in. `void`, `null` and `undefined` come last because that
// is where a union reads best and where TypeScript itself puts them: `string | undefined`, not the
// other way round.
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
	params:      []Param, // in source order
	result:      Type_ID,
	required:    int, // a call has to supply this many; the rest are optional or the rest parameter
	variadic:    bool, // the last parameter is `...xs: T[]`, so a call may pass any number past it
	// The type variables a call has to work out, as `map<U>` has U. Only a signature of the lib file
	// has any: generics of one's own are v2.
	type_params: []Type_ID,
}

// Param borrows its name from the tree and prints it in a diagnostic; the name takes no part in
// type identity.
Param :: struct {
	name: string,
	type: Type_ID,
}

// Union holds two or more members, in canonical order, with no duplicates and never a union among
// them. A union of one member is that member, and a union of none is `never`.
Union :: struct {
	members: []Type_ID,
}

// Decl_Ref names the declaration a named type came from: an ast.Interface_Decl or an ast.Type_Param.
// It is a fact of the frozen Program and so reads the same in every partition, which is what lets a
// type that holds itself be interned and ordered at all. NO_DECL is the zero value and means the type
// was written out in place, since node zero of a file is its Module and declares nothing.
Decl_Ref :: struct {
	file: source.File_ID,
	node: ast.Node_ID,
}

NO_DECL :: Decl_Ref{}

// Object is an object type: an `interface`, a `{ ... }` type written in place, or the type of an
// object literal. The fields are in canonical order, by name, which is the order requirements 3.3
// makes the memory layout from.
Object :: struct {
	fields: []Field,
	name:   string, // the interface name, borrowed from the tree, for printing only; "" without one
	decl:   Decl_Ref, // NO_DECL for an object type written in place
	args:   []Type_ID, // the type arguments of decl; empty unless the declaration is generic
}

// Field counts `optional` as part of the field set, so it takes part in assignability, as
// requirements 3.3 says; `readonly` only rejects a write and is ignored when types are compared, as
// it is in TypeScript.
Field :: struct {
	name:     string,
	type:     Type_ID,
	optional: bool,
	readonly: bool,
}

// Array is `T[]`, which is the same type as `Array<T>`. Elements are unboxed (requirements 3.6), so
// the element type is invariant: a `number[]` buffer is not a `(number | string)[]` buffer, and tsnc
// rejects the assignment that tsc allows.
Array :: struct {
	element: Type_ID,
}

// Type_Var is a type parameter of a generic lib declaration before anything instantiates it: `T` of
// `Array<T>` while its members are read, `U` of `map<U>` until a call works it out from the arrow it
// is given.
Type_Var :: struct {
	name: string, // borrowed from the tree, for printing
	decl: Decl_Ref, // the ast.Type_Param that declares it, which is its identity
}

// Overload holds the signatures one lib member declares under one name, as `reduce` does with and
// without an initial value. A call takes the first whose arity fits, which is what src/lib/lib.d.ts
// says it relies on.
Overload :: struct {
	signatures: []Type_ID,
}

// Table is not part of the result: Check_Result carries the frozen rows alone, because a caller
// reads types and never makes them.
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

// literal_type folds a negative zero into zero: parse reads the minus of `-0` into the value, while
// TypeScript has one literal type for both and `-0 === 0` at run time.
@(private)
literal_type :: proc(table: ^Table, value: ast.Literal) -> Type_ID {
	value := value
	if number, is_number := value.(f64); is_number && number == 0 {
		value = f64(0)
	}
	return intern(table, Literal{value = value})
}

// function_type takes params and type_params that may be scratch: intern copies what it keeps.
@(private)
function_type :: proc(
	table: ^Table,
	params: []Param,
	result: Type_ID,
	required: int,
	variadic: bool,
	type_params: []Type_ID = nil,
) -> Type_ID {
	function := Function {
		params      = params,
		result      = result,
		required    = required,
		variadic    = variadic,
		type_params = type_params,
	}
	return intern(table, function)
}

@(private)
array_type :: proc(table: ^Table, element: Type_ID) -> Type_ID {
	return intern(table, Array{element = element})
}

@(private)
type_var_type :: proc(table: ^Table, name: string, decl: Decl_Ref) -> Type_ID {
	return intern(table, Type_Var{name = name, decl = decl})
}

@(private)
overload_type :: proc(table: ^Table, signatures: []Type_ID) -> Type_ID {
	if len(signatures) == 1 {
		return signatures[0]
	}
	return intern(table, Overload{signatures = signatures})
}

// plain_object_type needs fields already in canonical order. They may be scratch: intern copies
// what it keeps.
@(private)
plain_object_type :: proc(table: ^Table, fields: []Field) -> Type_ID {
	return intern(table, Object{fields = fields})
}

// reserve_object gives a named object its row before its members are read, and says whether the row
// is new. A member that names the object again comes back here and finds the reserved row, which is
// how `interface Node { next: Node | undefined }` gets interned at all. The caller fills the row with
// finish_object once the members are read, and until then the object reads as one with no fields.
@(private)
reserve_object :: proc(
	table: ^Table,
	name: string,
	decl: Decl_Ref,
	args: []Type_ID,
) -> (
	id: Type_ID,
	fresh: bool,
) {
	strings.builder_reset(&table.key)
	write_key(&table.key, Object{name = name, decl = decl, args = args})
	probe := strings.to_string(table.key)
	if existing, found := table.by_key[probe]; found {
		return existing, false
	}

	owned := make([]Type_ID, len(args), table.allocator)
	copy(owned, args)
	id = Type_ID(len(table.types))
	append(&table.types, Object{name = name, decl = decl, args = owned})
	table.by_key[strings.clone(probe, table.allocator)] = id
	return id, true
}

// finish_object copies fields, so they may be scratch.
@(private)
finish_object :: proc(table: ^Table, id: Type_ID, fields: []Field) {
	object := table.types[id].(Object)
	object.fields = clone_fields(fields, table.allocator)
	table.types[id] = object
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

// add_member inserts in place, where the canonical order puts the member. A union has a handful of
// members at most, so that keeps this a plain loop and needs no comparator that carries the table
// with it.
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

// intern takes a `type` whose parts may be scratch: a type that is already there is found by its
// key alone, and only a new one copies its parts into the table's allocator.
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
	case Basic_Kind, Literal, Array, Type_Var:
	// No parts to copy.
	case Function:
		owned = Function {
			params      = clone_params(v.params, table.allocator),
			result      = v.result,
			required    = v.required,
			variadic    = v.variadic,
			type_params = clone_ids(v.type_params, table.allocator),
		}
	case Union:
		owned = Union {
			members = clone_ids(v.members, table.allocator),
		}
	case Overload:
		owned = Overload {
			signatures = clone_ids(v.signatures, table.allocator),
		}
	case Object:
		// A named object never arrives here: reserve_object gives it its row before its members are
		// read, because a member may name the object itself.
		assert(v.decl == NO_DECL, "a named object is interned by reserve_object")
		owned = Object {
			fields = clone_fields(v.fields, table.allocator),
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

@(private)
clone_fields :: proc(fields: []Field, allocator: runtime.Allocator) -> []Field {
	owned := make([]Field, len(fields), allocator)
	copy(owned, fields)
	return owned
}

@(private)
clone_ids :: proc(ids: []Type_ID, allocator: runtime.Allocator) -> []Type_ID {
	owned := make([]Type_ID, len(ids), allocator)
	copy(owned, ids)
	return owned
}

// write_key builds the key from the Type_ID values of the parts, which are interned already, so it
// stays short and it always terminates: a type that names itself does so through a named object,
// whose key is its declaration and not its members. A parameter name and an interface name are left
// out, because neither is part of the type. The key is internal: it is never printed and never
// ordered.
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
		for type_param in v.type_params {
			strings.write_byte(b, '<')
			strings.write_u64(b, u64(type_param))
		}
		for param in v.params {
			strings.write_byte(b, ',')
			strings.write_u64(b, u64(param.type))
		}
		strings.write_byte(b, '>')
		strings.write_u64(b, u64(v.result))
	case Union:
		strings.write_string(b, "u")
		write_id_key(b, v.members)
	case Overload:
		strings.write_string(b, "x")
		write_id_key(b, v.signatures)
	case Array:
		strings.write_string(b, "a")
		strings.write_u64(b, u64(v.element))
	case Type_Var:
		strings.write_string(b, "v")
		write_decl_key(b, v.decl)
	case Object:
		if v.decl != NO_DECL {
			strings.write_string(b, "o")
			write_decl_key(b, v.decl)
			write_id_key(b, v.args)
			return
		}
		strings.write_string(b, "O")
		for field in v.fields {
			strings.write_byte(b, ',')
			strings.write_quoted_string(b, field.name)
			strings.write_byte(b, '?' if field.optional else '-')
			strings.write_byte(b, 'r' if field.readonly else '-')
			strings.write_u64(b, u64(field.type))
		}
	}
}

@(private)
write_id_key :: proc(b: ^strings.Builder, ids: []Type_ID) {
	for id in ids {
		strings.write_byte(b, ',')
		strings.write_u64(b, u64(id))
	}
}

@(private)
write_decl_key :: proc(b: ^strings.Builder, decl: Decl_Ref) {
	strings.write_u64(b, u64(decl.file))
	strings.write_byte(b, ':')
	strings.write_u64(b, u64(decl.node))
}

// Canonical order.

// compare_types orders two types by structure: negative when a comes first, zero when they are one
// type. It reads no Type_ID as a number, so two checkers that built one union independently sort it
// the same way. It terminates because the one type that can hold itself, a named object, is settled
// by its declaration before anything looks at a field type.
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
	case Overload:
		return compare_members(types, v.signatures, right.(Overload).signatures)
	case Array:
		return compare_types(types, v.element, right.(Array).element)
	case Type_Var:
		return compare_decls(v.decl, right.(Type_Var).decl)
	case Object:
		return compare_objects(types, v, right.(Object))
	}
	// Two types with no parts and one rank are one type, which the first line already answered.
	return 0
}

// rank is where a kind of type stands in the canonical order: the kinds with no parts first, in the
// order of Basic_Kind, then the literals, then functions, then unions, then the kinds that hold a
// reference, which go last so that no union written before them changes how it prints.
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
	case Array:
		return BASIC + 5
	case Object:
		return BASIC + 6
	case Type_Var:
		return BASIC + 7
	case Overload:
		return BASIC + 8
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

// compare_objects orders a named object by its declaration and one written in place by its fields.
// A declaration is a number the Program fixed, so every partition reads it the same way, and asking
// for it first settles the two cases the fields cannot answer: an object that holds itself, and one
// whose row is reserved but whose fields are not read yet. An object written in place never holds
// itself and is always built out of types that already exist, so its fields terminate.
@(private)
compare_objects :: proc(types: []Type, a, b: Object) -> int {
	if a.decl != b.decl {
		return compare_decls(a.decl, b.decl)
	}
	if a.decl != NO_DECL {
		// One declaration and one set of arguments is one type, which compare_types already
		// answered, so the arguments are what differ here.
		for arg, i in a.args {
			if order := compare_types(types, arg, b.args[i]); order != 0 {
				return order
			}
		}
		return 0
	}

	if len(a.fields) != len(b.fields) {
		return -1 if len(a.fields) < len(b.fields) else 1
	}
	for field, i in a.fields {
		other := b.fields[i]
		if order := strings.compare(field.name, other.name); order != 0 {
			return order
		}
		if field.optional != other.optional {
			return -1 if !field.optional else 1
		}
		if field.readonly != other.readonly {
			return -1 if !field.readonly else 1
		}
		if order := compare_types(types, field.type, other.type); order != 0 {
			return order
		}
	}
	return 0
}

@(private)
compare_decls :: proc(a, b: Decl_Ref) -> int {
	if a.file != b.file {
		return -1 if a.file < b.file else 1
	}
	if a.node != b.node {
		return -1 if a.node < b.node else 1
	}
	return 0
}

// Reading types.

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
	case Basic_Kind, Function, Object, Array, Type_Var, Overload:
		// An object keeps its fields as they were built, where each one was widened already, and an
		// array keeps its element type, which the literal that made it widened.
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
// Nullish is the other answer of that last test: what a value turned out to be when `??` took its
// right side, and what `x === null` leaves behind.
@(private)
Part :: enum u8 {
	Falsy,
	Truthy,
	Not_Nullish,
	Nullish,
}

// part_of keeps only the surviving part, which is what makes `name || "none"` a `string` where name
// is `string | undefined`: tsc types it the same way, and the differential gate of T4.7 runs
// `tsc --strict` over every program first.
//
// A member of a union that survives nothing comes back as `never`, and union_type then drops it,
// which is how `string | undefined` loses its `undefined`.
@(private)
part_of :: proc(table: ^Table, id: Type_ID, part: Part) -> Type_ID {
	switch v in table.types[id] {
	case Basic_Kind:
		#partial switch v {
		case .Null, .Undefined, .Void:
			// All three are falsy, and the first two are the pair `??` and `=== null` ask about.
			return id if part == .Falsy || part == .Nullish else NEVER
		case .Any, .Unknown, .Error:
			return id
		}
		if part == .Nullish {
			return NEVER // a boolean, a number and a string are never null or undefined
		}
		#partial switch v {
		case .Boolean:
			return literal_type(table, false) if part == .Falsy else id
		case .Number:
			return literal_type(table, f64(0)) if part == .Falsy else id
		case .String:
			return literal_type(table, "") if part == .Falsy else id
		}
		return NEVER // `never` has no values, so no part of it survives anything
	case Literal:
		// A literal is a number, a string or a boolean, never null or undefined.
		if part == .Not_Nullish {
			return id
		}
		if part == .Nullish {
			return NEVER
		}
		return id if is_falsy(v.value) == (part == .Falsy) else NEVER
	case Function, Object, Array, Overload:
		// A reference is always truthy, and so is a function value, and neither is ever null.
		return id if part == .Truthy || part == .Not_Nullish else NEVER
	case Type_Var:
		return id // nothing is known about it until a call works it out
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

// Trail is the pairs of types a comparison is already inside. Two interfaces that name themselves
// would otherwise be compared forever, so a pair already on the trail answers yes, which is the usual
// rule for structural types that hold themselves. fits owns one buffer for the whole check: assignable
// never calls back into the checker, so no second comparison can be running.
@(private)
Trail :: [dynamic][2]Type_ID

@(private)
assignable :: proc(types: []Type, source, target: Type_ID, trail: ^Trail) -> bool {
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
			if !assignable(types, member, target, trail) {
				return false
			}
		}
		return true
	}
	// A value fits a union when it fits one of the members.
	if members, is_union := types[target].(Union); is_union {
		for member in members.members {
			if assignable(types, source, member, trail) {
				return true
			}
		}
		return false
	}

	// An overloaded member fits wherever one of its signatures does.
	if overload, is_overload := types[source].(Overload); is_overload {
		for signature in overload.signatures {
			if assignable(types, signature, target, trail) {
				return true
			}
		}
		return false
	}

	source_function, source_is_function := types[source].(Function)
	target_function, target_is_function := types[target].(Function)
	if source_is_function && target_is_function {
		return function_assignable(types, source_function, target_function, trail)
	}

	source_array, source_is_array := types[source].(Array)
	target_array, target_is_array := types[target].(Array)
	if source_is_array && target_is_array {
		// Invariant, because requirements 3.6 stores elements unboxed: a `number[]` buffer holds f64
		// and a `(number | string)[]` buffer holds tagged values, so one is not the other. tsc allows
		// the assignment; tsnc may be stricter where its model says so (requirements 5).
		return source_array.element == target_array.element
	}

	source_object, source_is_object := types[source].(Object)
	target_object, target_is_object := types[target].(Object)
	if source_is_object && target_is_object {
		return object_assignable(types, source, target, source_object, target_object, trail)
	}
	return false
}

// function_assignable is the rule for a function value: every call the target allows has to be a
// call the source accepts. So the source may ask for fewer arguments but never for more, each
// parameter is compared the other way round, and the result has to fit unless the target throws it
// away.
//
// A rest parameter arrives as one array and a positional one as a value, so a signature with one
// and a signature without are passed differently and neither is the other: the same argument arrays
// are invariant for (requirements 3.6). tsc allows some of these mixes; tsnc may be stricter where
// its model says so (requirements 5).
//
// An argument the target may leave out arrives as `undefined`, so a source that insists on a value
// in that position does not fit either.
@(private)
function_assignable :: proc(types: []Type, source, target: Function, trail: ^Trail) -> bool {
	if source.variadic != target.variadic {
		return false
	}
	if source.variadic && len(source.params) != len(target.params) {
		return false
	}
	if !target.variadic && source.required > len(target.params) {
		return false
	}
	shared := min(len(source.params), len(target.params))
	for i in 0 ..< shared {
		if !assignable(types, target.params[i].type, source.params[i].type, trail) {
			return false
		}
		if i >= target.required && i < source.required {
			if !assignable(types, UNDEFINED, source.params[i].type, trail) {
				return false
			}
		}
	}
	if target.result == VOID {
		return true
	}
	return assignable(types, source.result, target.result, trail)
}

// object_assignable is the exact-type rule of requirements 3.3: an object fits only a type with the
// same set of fields, where a field written `x?: T` counts as its own kind of field. The fields of
// both are in canonical order, so one walk settles it. `readonly` is left out, as it is in TypeScript:
// it says who may write the field, not what the field holds.
@(private)
object_assignable :: proc(
	types: []Type,
	source_id, target_id: Type_ID,
	source, target: Object,
	trail: ^Trail,
) -> bool {
	if len(source.fields) != len(target.fields) {
		return false
	}

	pair := [2]Type_ID{source_id, target_id}
	for seen in trail^ {
		if seen == pair {
			// The two are already being compared further up, so this is the question that asked it.
			// Answering yes is what makes two interfaces that name themselves comparable at all.
			return true
		}
	}
	append(trail, pair)
	defer pop(trail)

	for field, i in source.fields {
		other := target.fields[i]
		if field.name != other.name || field.optional != other.optional {
			return false
		}
		if !assignable(types, field.type, other.type, trail) {
			return false
		}
	}
	return true
}

// list_widenings adds to `out` every pair of object types that an accepted flow of source into
// target passes through. A union source flows member by member, a union target takes the members
// the source fits, and two objects walk their fields, which the exact-type rule has matched one for
// one. Arrays are invariant and function values wait for closures, so neither adds a pair. A pair
// already in the list ends the walk, which is what stops it on an interface that names itself.
@(private)
list_widenings :: proc(
	types: []Type,
	source, target: Type_ID,
	out: ^[dynamic]Widening,
	trail: ^Trail,
) {
	if source == target {
		return
	}
	if members, is_union := types[source].(Union); is_union {
		for member in members.members {
			list_widenings(types, member, target, out, trail)
		}
		return
	}
	if members, is_union := types[target].(Union); is_union {
		for member in members.members {
			if assignable(types, source, member, trail) {
				list_widenings(types, source, member, out, trail)
			}
		}
		return
	}

	source_object, source_is_object := types[source].(Object)
	target_object, target_is_object := types[target].(Object)
	if !source_is_object || !target_is_object {
		return
	}
	pair := Widening {
		source = source,
		target = target,
	}
	if slice.contains(out[:], pair) {
		return
	}
	append(out, pair)
	for field, i in source_object.fields {
		list_widenings(types, field.type, target_object.fields[i].type, out, trail)
	}
}

// Printing a type.

// type_text is how a type reads: `number`, `"circle"`, `(a: number) => string`, `number | string`,
// `Point`, `{ x: number; y: number }`, `number[]`. types is the table the id belongs to, which is
// Check_Result.types.
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
	case Overload:
		// TypeScript writes an overloaded member as the intersection of its signatures, and the only
		// ones tsnc has are the two of `reduce`.
		for signature, i in v.signatures {
			if i > 0 {
				strings.write_string(b, " & ")
			}
			write_type(b, types, signature)
		}
	case Type_Var:
		strings.write_string(b, v.name)
	case Array:
		// A union or a function element needs brackets, or the `[]` would bind to the last member.
		element := types[v.element]
		_, is_union := element.(Union)
		_, is_function := element.(Function)
		brackets := is_union || is_function
		if brackets {
			strings.write_byte(b, '(')
		}
		write_type(b, types, v.element)
		if brackets {
			strings.write_byte(b, ')')
		}
		strings.write_string(b, "[]")
	case Object:
		write_object(b, types, v)
	}
}

// write_object prints a named object as its name, the way tsc does: a name is what keeps a message
// about a type that holds itself finite and short.
@(private)
write_object :: proc(b: ^strings.Builder, types: []Type, object: Object) {
	if object.name != "" {
		strings.write_string(b, object.name)
		if len(object.args) > 0 {
			strings.write_byte(b, '<')
			for arg, i in object.args {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				write_type(b, types, arg)
			}
			strings.write_byte(b, '>')
		}
		return
	}

	if len(object.fields) == 0 {
		strings.write_string(b, "{}")
		return
	}
	strings.write_string(b, "{ ")
	for field, i in object.fields {
		if i > 0 {
			strings.write_string(b, "; ")
		}
		if field.readonly {
			strings.write_string(b, "readonly ")
		}
		strings.write_string(b, field.name)
		if field.optional {
			strings.write_byte(b, '?')
		}
		strings.write_string(b, ": ")
		write_type(b, types, field.type)
	}
	strings.write_string(b, " }")
}

@(private)
write_function :: proc(b: ^strings.Builder, types: []Type, function: Function) {
	if len(function.type_params) > 0 {
		strings.write_byte(b, '<')
		for type_param, i in function.type_params {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			write_type(b, types, type_param)
		}
		strings.write_byte(b, '>')
	}
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

// write_number goes through strings.write_float, which drops the `+` that strconv writes for a
// positive number and no TypeScript type ever shows.
//
// Where this differs from the program it compiles: the ECMAScript `Number::toString` rules of
// requirements 3.1, with their 1e21 and 1e-7 thresholds, live in the runtime, in `rt/num`. A
// diagnostic is read by a person, not compared with Node, so the shortest decimal form does.
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
