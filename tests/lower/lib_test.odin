package lower_tests

import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/ast"
import "../../src/lower"
import "../../src/parse"

/*
The lib file and the strategy table are two halves of one thing: src/lib/lib.d.ts says what the
standard library is, and lower.LIB_STRATEGIES says what the compiler emits for each name. A name in
one and not the other is a hole, so this file reads the real lib and compares the two sets both
ways.

Which half a name belongs to follows from the lib itself. An interface a `declare const` names is
reached through that value, as `Math` is; an interface nothing declares a value of types a
primitive, as `String` does, and its members are reached through a value of that type. Adding an
interface to the lib therefore adds rows to one half or the other without this test being touched.
*/

// Name is one entry of the table: which half, the name it hangs off, and the member.
@(private = "file")
Name :: struct {
	owner:  lower.Owner,
	root:   string,
	member: string,
}

@(test)
every_lib_name_has_a_strategy :: proc(t: ^testing.T) {
	declared := lib_names(t)
	for want in declared {
		_, found := lower.lib_strategy(want.owner, want.root, want.member)
		testing.expectf(t, found, "the strategy table has no row for %v", want)
	}
}

@(test)
every_strategy_names_something_the_lib_declares :: proc(t: ^testing.T) {
	declared := lib_names(t)
	for entry in lower.LIB_STRATEGIES {
		have := Name {
			owner  = entry.owner,
			root   = entry.root,
			member = entry.member,
		}
		testing.expectf(t, slice.contains(declared, have), "the lib declares no %v", have)
	}
}

@(test)
the_table_names_nothing_twice :: proc(t: ^testing.T) {
	seen := make([dynamic]Name, context.temp_allocator)
	for entry in lower.LIB_STRATEGIES {
		have := Name {
			owner  = entry.owner,
			root   = entry.root,
			member = entry.member,
		}
		testing.expectf(t, !slice.contains(seen[:], have), "two rows for %v", have)
		append(&seen, have)
	}
}

@(test)
the_math_names_the_ir_has_an_intrinsic_for_use_it :: proc(t: ^testing.T) {
	// The four that do not are named in the table with the reason; everything else of Math is an
	// intrinsic, an operator, a constant, a runtime call or a shape lower builds.
	for entry in lower.LIB_STRATEGIES {
		if entry.root != "Math" || entry.owner != .Value {
			continue
		}
		later, is_later := entry.strategy.(lower.Later)
		if !is_later {
			continue
		}
		expected := []string{"`Math.clz32`", "`Math.fround`", "`Math.hypot`", "`Math.imul`"}
		testing.expectf(
			t,
			slice.contains(expected, later.construct),
			"Math.%s is not compiled and is not one of the four the IR cannot say yet",
			entry.member,
		)
	}
}

@(private = "file")
lib_names :: proc(t: ^testing.T) -> []Name {
	tree, diagnostics := parse.parse_file(LIB_TEXT, LIB, context.temp_allocator)
	testing.expectf(t, len(diagnostics) == 0, "the lib file does not parse: %v", diagnostics)

	interfaces := make(map[string]ast.Node_ID, context.temp_allocator)
	values := make([dynamic]Name, context.temp_allocator)
	typed_by := make(map[string]string, context.temp_allocator) // value name to interface name

	for id in tree.nodes[ast.ROOT].variant.(ast.Module).statements {
		#partial switch v in tree.nodes[id].variant {
		case ast.Interface_Decl:
			interfaces[v.name.text] = v.body
		case ast.Function_Decl:
			if .Declare in v.modifiers {
				append(&values, Name{owner = .Value, root = v.name.text})
			}
		case ast.Var_Decl:
			if .Declare not_in v.modifiers {
				continue
			}
			for declarator in v.declarators {
				node := tree.nodes[declarator].variant.(ast.Declarator)
				reference, is_reference := tree.nodes[node.type].variant.(ast.Type_Ref)
				if !is_reference {
					append(&values, Name{owner = .Value, root = node.name.text})
					continue
				}
				typed_by[node.name.text] = reference.name.text
			}
		}
	}

	out := make([dynamic]Name, context.temp_allocator)
	append(&out, ..values[:])

	reached := make(map[string]bool, context.temp_allocator)
	for value, name in typed_by {
		reached[name] = true
		body, found := interfaces[name]
		testing.expectf(t, found, "`declare const %s: %s` names no interface", value, name)
		for member in members_of(tree, body) {
			append(&out, Name{owner = .Value, root = value, member = member})
		}
	}
	for name, body in interfaces {
		if reached[name] {
			continue
		}
		for member in members_of(tree, body) {
			append(&out, Name{owner = .Instance, root = name, member = member})
		}
	}

	// A map has no stable order; the answer is sorted so that a failure reads the same every run.
	slice.sort_by(out[:], proc(a, b: Name) -> bool {
		if a.owner != b.owner {
			return a.owner < b.owner
		}
		if a.root != b.root {
			return a.root < b.root
		}
		return a.member < b.member
	})
	return dedup(out[:])
}

// members_of is the name of each member of an interface body, each one once: `reduce` is two
// signatures under one name.
@(private = "file")
members_of :: proc(tree: ast.File_AST, body: ast.Node_ID) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for id in tree.nodes[body].variant.(ast.Object_Type).members {
		name := tree.nodes[id].variant.(ast.Property_Signature).name.text
		if !slice.contains(out[:], name) {
			append(&out, name)
		}
	}
	return out[:]
}

@(private = "file")
dedup :: proc(sorted: []Name) -> []Name {
	out := make([dynamic]Name, 0, len(sorted), context.temp_allocator)
	for value in sorted {
		if len(out) == 0 || out[len(out) - 1] != value {
			append(&out, value)
		}
	}
	return out[:]
}

@(test)
the_lib_declares_no_name_with_a_dot_in_it :: proc(t: ^testing.T) {
	// The table keys a member by its bare name, so a qualified one would never be found.
	for entry in lower.LIB_STRATEGIES {
		testing.expect(t, !strings.contains(entry.member, "."), entry.member)
	}
}
