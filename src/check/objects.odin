package check

import "core:slice"
import "core:strings"

import "../ast"
import "../bind"
import "../program"
import "../source"

// Named types.

// Lib_Types are the declarations of the lib module that check has to find by name rather than by
// use: `Array<T>`, which every `T[]` takes its members from, and the interfaces that hold what a
// string and a number can do. They are looked up once, the first time anything asks.
@(private)
Lib_Types :: struct {
	ready:  bool,
	array:  bind.Symbol_ID,
	string: bind.Symbol_ID,
	number: bind.Symbol_ID,
}

@(private)
lib_types :: proc(c: ^Checker) -> Lib_Types {
	if !c.lib.ready {
		lib := c.program.bound[program.LIB]
		c.lib = Lib_Types {
			ready  = true,
			array  = bind.lookup(lib, bind.MODULE_SCOPE, "Array", .Type),
			string = bind.lookup(lib, bind.MODULE_SCOPE, "String", .Type),
			number = bind.lookup(lib, bind.MODULE_SCOPE, "Number", .Type),
		}
	}
	return c.lib
}

// type_ref_type is the type a name in a type position stands for: `Point`, `Array<number>`, `T`,
// `m.Point`.
@(private)
type_ref_type :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Type_Ref) -> Type_ID {
	// The arguments are written here, so they are read here, before the search moves to the file
	// that declares the name.
	args := make([dynamic]Type_ID, 0, len(node.args), context.temp_allocator)
	for arg in node.args {
		append(&args, resolve_type(c, arg))
	}

	if node.qualifier.text != "" {
		return namespace_type(c, id, node, args[:])
	}

	ref := resolve_name(c, id, node.name.text, .Type)
	if ref.symbol == bind.NO_SYMBOL {
		report_unknown_name(c, node.name.text, node.name.span)
		return ERROR
	}
	kind := c.program.bound[ref.file].symbols[ref.symbol].kind
	if kind == .Namespace_Import {
		// `let x: m` names a module where a type belongs. The name after the dot is what stands for
		// a type, so the message asks for one.
		report(c, .Namespace_As_Value, node.name.span, node.name.text)
		return ERROR
	}
	if kind == .Import {
		target, err := resolved_import(c, ref, .Type)
		if err == .Not_A_Type {
			// The module has the name as a value only, which is what a name with no type behind it
			// answers here whether it was imported or declared in this file.
			report_unknown_name(c, node.name.text, node.name.span)
			return ERROR
		}
		if err != .None {
			return ERROR // check_import has reported it at the specifier
		}
		ref = target
	}
	set_symbol(c, id, ref)
	return named_type(c, ref, args[:], node.name)
}

// named_type is the type of a symbol used in a type position. It is a path of its own, and not
// type_of_symbol: an interface may legally name itself, while a value whose type needs its own type
// has no answer at all.
@(private)
named_type :: proc(c: ^Checker, ref: Symbol_Ref, args: []Type_ID, name: ast.Name) -> Type_ID {
	symbol := c.program.bound[ref.file].symbols[ref.symbol]
	#partial switch symbol.kind {
	case .Interface:
		// `Array<T>` written as a type is the array type itself, so `number[]` and `Array<number>`
		// are one type and, in T5.7, one layout. The interface behind the name holds the methods,
		// which apparent_type reaches through instantiation.
		if ref.file == program.LIB && ref.symbol == lib_types(c).array {
			if !type_args_fit(c, name, len(args), 1) {
				return ERROR
			}
			return array_type(&c.table, args[0])
		}
		return interface_type(c, ref, symbol, args, name)
	case .Type_Alias:
		return alias_type(c, ref, symbol, args, name)
	case .Type_Param:
		if !type_args_fit(c, name, len(args), 0) {
			return ERROR
		}
		return type_param_type(c, ref, symbol)
	}
	// Every kind that is a type is above. type_ref_type follows an imported name to the declaration
	// behind it before asking, so an alias never arrives here, and a value in a type position is a
	// name bind answered for in the other half.
	return ERROR
}

// interface_type is the object type of an interface, with args in force while its members are read.
// The row is reserved before that, so a member that names the interface again finds it instead of
// asking for it once more, which is what lets `interface Node { next: Node | undefined }` exist.
@(private)
interface_type :: proc(
	c: ^Checker,
	ref: Symbol_Ref,
	symbol: bind.Symbol,
	args: []Type_ID,
	name: ast.Name,
) -> Type_ID {
	node := symbol.declaration
	previous := move_to(c, ref.file)
	defer c.at = previous

	declaration := c.at.tree.nodes[node].variant.(ast.Interface_Decl)
	if !type_args_fit(c, name, len(args), len(declaration.type_params)) {
		return ERROR
	}

	id, fresh := reserve_object(&c.table, symbol.name.text, {file = ref.file, node = node}, args)
	if !fresh {
		return id
	}

	drop_facts_of_instance(c, args)
	restore := bind_type_params(c, ref.file, declaration.type_params, args)
	defer unbind_type_params(c, restore)

	body := c.at.tree.nodes[declaration.body].variant.(ast.Object_Type)
	finish_object(&c.table, id, object_fields(c, body.members))
	// The declaration itself holds the type it declares. An instantiation writes nothing, since one
	// tree stands behind every instance of a generic declaration.
	set_type(c, node, id)
	return id
}

// alias_type is what a `type` alias stands for. An alias is transparent, as it is in TypeScript, so
// one that names itself has nothing to stand for and is rejected; an interface is how a type that
// holds itself is written.
//
// The answer is cached by symbol where the alias takes no arguments, which also keeps a mistake
// inside the alias from being reported once per use. The cache is the one type_of_symbol uses, and
// the two never meet: an alias has a type meaning and no value meaning.
@(private)
alias_type :: proc(
	c: ^Checker,
	ref: Symbol_Ref,
	symbol: bind.Symbol,
	args: []Type_ID,
	name: ast.Name,
) -> Type_ID {
	node := symbol.declaration
	decl := Decl_Ref {
		file = ref.file,
		node = node,
	}
	if decl in c.aliases {
		report(c, .Circular_Type, name.span, name.text)
		return ERROR
	}
	if cached, found := c.symbol_types[ref]; found && len(args) == 0 {
		return cached
	}

	previous := move_to(c, ref.file)
	defer c.at = previous

	declaration := c.at.tree.nodes[node].variant.(ast.Type_Alias_Decl)
	if !type_args_fit(c, name, len(args), len(declaration.type_params)) {
		return ERROR
	}

	drop_facts_of_instance(c, args)
	c.aliases[decl] = true
	defer delete_key(&c.aliases, decl)
	restore := bind_type_params(c, ref.file, declaration.type_params, args)
	defer unbind_type_params(c, restore)

	type := resolve_type(c, declaration.type)
	if len(args) == 0 {
		c.symbol_types[ref] = type
	}
	return set_type(c, node, type)
}

// type_param_type is what one type parameter stands for: the argument in force, or the type variable
// itself while the declaration is read on its own.
@(private)
type_param_type :: proc(c: ^Checker, ref: Symbol_Ref, symbol: bind.Symbol) -> Type_ID {
	decl := Decl_Ref {
		file = ref.file,
		node = symbol.declaration,
	}
	if bound, found := c.bindings[decl]; found {
		return bound
	}
	if ref.file == program.LIB {
		return type_var_type(&c.table, symbol.name.text, decl)
	}
	// Generics of one's own are v2 (requirements 2.2), and check_declaration_rules has already
	// reported the declaration that wrote this parameter, so the use of it says nothing more.
	return ERROR
}

// Type arguments.

// Restore is what bind_type_params has to put back once a declaration has been read.
@(private)
Restore :: struct {
	decl:  Decl_Ref,
	type:  Type_ID,
	bound: bool, // whether there was a binding at all before this one
}

@(private)
bind_type_params :: proc(
	c: ^Checker,
	file: source.File_ID,
	type_params: []ast.Node_ID,
	args: []Type_ID,
) -> []Restore {
	restore := make([]Restore, len(type_params), context.temp_allocator)
	for node, i in type_params {
		decl := Decl_Ref {
			file = file,
			node = node,
		}
		previous, bound := c.bindings[decl]
		restore[i] = {
			decl  = decl,
			type  = previous,
			bound = bound,
		}
		c.bindings[decl] = args[i]
	}
	return restore
}

@(private)
unbind_type_params :: proc(c: ^Checker, restore: []Restore) {
	for entry in restore {
		if entry.bound {
			c.bindings[entry.decl] = entry.type
			continue
		}
		delete_key(&c.bindings, entry.decl)
	}
}

// drop_facts_of_instance stops an instantiation from writing facts about the declaration's nodes.
// One tree of `Array<T>` stands behind every `Array<number>` and `Array<string>`, and a node holds
// one type, so the instance would overwrite what the declaration itself recorded. lower reads the
// instance through the expression that used it, never through the lib tree.
@(private)
drop_facts_of_instance :: proc(c: ^Checker, args: []Type_ID) {
	if len(args) == 0 {
		return
	}
	c.at.node_types = nil
	c.at.node_symbols = nil
	c.at.node_signatures = nil
}

// type_args_fit reports a name given the wrong number of type arguments.
@(private)
type_args_fit :: proc(c: ^Checker, name: ast.Name, given, want: int) -> bool {
	if given == want {
		return true
	}
	report(c, .Type_Argument_Count, name.span, name.text, type_argument_text(c, want))
	return false
}

@(private)
type_argument_text :: proc(c: ^Checker, count: int) -> string {
	b := strings.builder_make(c.allocator)
	if count == 0 {
		strings.write_string(&b, "no type arguments")
		return strings.to_string(b)
	}
	strings.write_int(&b, count)
	strings.write_string(&b, " type argument" if count == 1 else " type arguments")
	return strings.to_string(b)
}

// Object types.

// object_fields reads the members of an object type into fields in canonical order, which is by
// name, as requirements 3.3 asks. A name declared more than once is an overload when every
// declaration is a signature, which is how the lib file writes `reduce`; anywhere else it is a
// mistake, and the first declaration stands.
@(private)
object_fields :: proc(c: ^Checker, members: []ast.Node_ID) -> []Field {
	fields := make([dynamic]Field, 0, len(members), context.temp_allocator)
	for id in members {
		member := c.at.tree.nodes[id].variant.(ast.Property_Signature)
		if !check_member_name(c, member.name) {
			// The type is still read, so a mistake inside it is found, and the member is left out:
			// a type with a prototype slot would let every reader of it ask for one.
			set_type(c, id, resolve_type(c, member.type))
			continue
		}
		type := set_type(c, id, resolve_type(c, member.type))
		field := Field {
			name     = member.name.text,
			type     = type,
			optional = .Optional in member.flags,
			readonly = .Readonly in member.flags,
		}
		add_field(c, &fields, field, member.name)
	}
	sort_fields(fields[:])
	return fields[:]
}

@(private)
add_field :: proc(c: ^Checker, fields: ^[dynamic]Field, field: Field, name: ast.Name) {
	for &existing in fields {
		if existing.name != field.name {
			continue
		}
		if is_signature(c, existing.type) && is_signature(c, field.type) {
			existing.type = joined_signatures(c, existing.type, field.type)
			return
		}
		report(c, .Duplicate_Field, name.span, name.text)
		return
	}
	append(fields, field)
}

@(private)
is_signature :: proc(c: ^Checker, id: Type_ID) -> bool {
	#partial switch _ in c.table.types[id] {
	case Function, Overload:
		return true
	}
	return false
}

// joined_signatures is the overload of everything two members declare under one name.
@(private)
joined_signatures :: proc(c: ^Checker, a, b: Type_ID) -> Type_ID {
	out := make([dynamic]Type_ID, 0, 4, context.temp_allocator)
	append_signatures(c, &out, a)
	append_signatures(c, &out, b)
	return overload_type(&c.table, out[:])
}

// append_signatures puts every signature a type offers a call into out, in the order they were
// declared. Anything that is not callable adds none.
@(private)
append_signatures :: proc(c: ^Checker, out: ^[dynamic]Type_ID, id: Type_ID) {
	#partial switch v in c.table.types[id] {
	case Function:
		append(out, id)
	case Overload:
		append(out, ..v.signatures)
	}
}

@(private)
sort_fields :: proc(fields: []Field) {
	slice.sort_by(fields, proc(a, b: Field) -> bool {
		return a.name < b.name
	})
}

// Reading an object.

// apparent_type is the object whose fields a member lookup searches. A primitive borrows the members
// the lib file declares for it, and an array borrows those of `Array<T>` instantiated with its
// element type, which is where the whole method list of requirements 2.2 comes from.
@(private)
apparent_type :: proc(c: ^Checker, id: Type_ID) -> Type_ID {
	#partial switch v in c.table.types[id] {
	case Object:
		return id
	case Array:
		element := [1]Type_ID{v.element}
		return lib_interface(c, lib_types(c).array, element[:])
	case Literal:
		return apparent_type(c, literal_base(v.value))
	case Basic_Kind:
		#partial switch v {
		case .String:
			return lib_interface(c, lib_types(c).string, nil)
		case .Number:
			return lib_interface(c, lib_types(c).number, nil)
		}
	}
	return ERROR
}

@(private)
lib_interface :: proc(c: ^Checker, id: bind.Symbol_ID, args: []Type_ID) -> Type_ID {
	if id == bind.NO_SYMBOL {
		return ERROR // a lib file without the declaration; the lib test is what catches that
	}
	symbol := c.program.bound[program.LIB].symbols[id]
	ref := Symbol_Ref {
		file   = program.LIB,
		symbol = id,
	}
	return interface_type(c, ref, symbol, args, symbol.name)
}

// field_of is the field of that name in the apparent type of id.
@(private)
field_of :: proc(c: ^Checker, id: Type_ID, name: string) -> (field: Field, found: bool) {
	if _, is_union := c.table.types[id].(Union); is_union {
		return union_field(c, id, name)
	}

	// The row has to be read after the search, and not indexed with it: an apparent type is
	// instantiated on the spot, and the table it goes into is the one being indexed.
	apparent := apparent_type(c, id)
	object, is_object := c.table.types[apparent].(Object)
	if !is_object {
		return {}, false
	}
	return find_field(object.fields, name)
}

// union_field is the field a whole union offers: one that every member has, holding whatever any of
// them holds. It is what makes the discriminant of a discriminated union readable before the union
// is taken apart, since `s.kind` is then the union of the literal types a test picks from. A name
// one member does not declare is a name the union does not have, as it is in TypeScript.
//
// A field is optional for the union where it is optional in any member, and readonly where it is
// readonly in any: a write has to be legal wherever the value could have come from.
@(private)
union_field :: proc(c: ^Checker, id: Type_ID, name: string) -> (field: Field, found: bool) {
	members := union_members(c, id)
	types := make([dynamic]Type_ID, 0, len(members), context.temp_allocator)
	optional, readonly := false, false
	for member in members {
		one, has := field_of(c, member, name)
		if !has {
			return {}, false
		}
		append(&types, one.type)
		optional ||= one.optional
		readonly ||= one.readonly
	}

	return Field {
			name = name,
			type = union_type(&c.table, types[:]),
			optional = optional,
			readonly = readonly,
		},
		true
}

// field_read_type is the type a field slot holds. A field written `x?: T` may be missing, and
// requirements 3.4 gives a missing one and `T | undefined` the same representation, so that is what
// the slot is worth. Every place that names the slot goes through here, so a read and a write agree
// on it; `Field.optional` itself is untouched, and two types still need the same set of fields.
@(private)
field_read_type :: proc(c: ^Checker, field: Field) -> Type_ID {
	return union_of(c, field.type, UNDEFINED) if field.optional else field.type
}

@(private)
find_field :: proc(fields: []Field, name: string) -> (field: Field, found: bool) {
	for candidate in fields {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// expected_object is the object type a literal is going into. A union is the one context that leaves
// a choice, and the literal makes it in two passes: the first asks for a member whose field names it
// could have **and** whose tags its own literal values fit, which is how a discriminated union is
// picked apart, and the second falls back to the names alone, so a tag that fits nothing is still
// measured against a member and gets one message.
//
// Several fitting members are the same shape under one set of tags, so the first in canonical order
// settles it and the answer stays the same in every partition.
@(private)
expected_object :: proc(
	c: ^Checker,
	expected: Type_ID,
	names: []string,
	tags: []Type_ID,
) -> (
	Type_ID,
	Object,
	bool,
) {
	#partial switch v in c.table.types[expected] {
	case Object:
		return expected, v, true
	case Union:
		for member in v.members {
			object, is_object := c.table.types[member].(Object)
			if is_object && object_takes(object, names) && object_tagged(c, object, names, tags) {
				return member, object, true
			}
		}
		for member in v.members {
			object, is_object := c.table.types[member].(Object)
			if is_object && object_takes(object, names) {
				return member, object, true
			}
		}
	}
	return ERROR, {}, false
}

// object_tagged reports whether every property the literal wrote out as a value fits the field of
// this member. A property written as anything else says nothing and is skipped.
@(private)
object_tagged :: proc(c: ^Checker, object: Object, names: []string, tags: []Type_ID) -> bool {
	for tag, i in tags {
		if tag == ERROR {
			continue
		}
		field, found := find_field(object.fields, names[i])
		if !found || !fits(c, tag, field_read_type(c, field)) {
			return false
		}
	}
	return true
}

// object_takes reports whether a literal with those field names could be an object of this type:
// every name is a field, and every field the literal leaves out was written `x?: T`.
@(private)
object_takes :: proc(object: Object, names: []string) -> bool {
	for name in names {
		if _, found := find_field(object.fields, name); !found {
			return false
		}
	}
	for field in object.fields {
		if field.optional {
			continue
		}
		if !slice.contains(names, field.name) {
			return false
		}
	}
	return true
}

// report_assign_failure says why a value does not fit where it is going. Two object types differ by
// which fields they have far more often than by what a field holds, and requirements 3.3 makes the
// set of fields the whole rule, so the message names the field instead of printing two shapes.
@(private)
report_assign_failure :: proc(c: ^Checker, span: source.Span, value, target: Type_ID) {
	value_object, value_is_object := c.table.types[value].(Object)
	target_object, target_is_object := c.table.types[target].(Object)
	if value_is_object && target_is_object {
		for field in value_object.fields {
			if _, found := find_field(target_object.fields, field.name); !found {
				report(c, .Field_Not_Found, span, field.name, text_of(c, target))
				return
			}
		}
		for field in target_object.fields {
			if _, found := find_field(value_object.fields, field.name); !found {
				report(c, .Missing_Field, span, field.name, text_of(c, target))
				return
			}
		}
	}
	report_types(c, .Type_Mismatch, span, value, target)
}
