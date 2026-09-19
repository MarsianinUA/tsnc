package parse_tests

import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/ast"

// LIB_TEXT is the lib file, embedded the way driver embeds it.
LIB_TEXT :: #load("../../src/lib/lib.d.ts", string)

@(test)
the_lib_file_parses_without_diagnostics :: proc(t: ^testing.T) {
	parsed := parse_checked(t, LIB_TEXT)
	testing.expectf(t, len(parsed.errors) == 0, "lib.d.ts: errors %v", parsed.errors)
}

@(test)
the_lib_file_declares_the_v1_standard_library :: proc(t: ^testing.T) {
	parsed := parse_checked(t, LIB_TEXT)
	declared := lib_declarations(parsed.tree)
	expected := slice.clone(LIB_DECLARATIONS[:], context.temp_allocator)
	slice.sort(declared)
	slice.sort(expected)
	missing, extra := sorted_differences(expected, declared)
	testing.expectf(
		t,
		len(missing) == 0 && len(extra) == 0,
		"lib.d.ts: missing %v, extra %v",
		missing,
		extra,
	)
}

// LIB_DECLARATIONS is every name lib.d.ts declares, in the form of lib_declarations, grouped by
// the item of the requirements 2.2 standard library it covers. The header of lib.d.ts says what
// the file leaves out or adds, and why.
@(rodata)
LIB_DECLARATIONS := [?]string {
	// console.log, console.error
	"Console.log",
	"Console.error",
	"console: Console",

	// process.argv, process.exit
	"Process.argv",
	"Process.exit",
	"process: Process",

	// Math, all of it but random
	"Math.E",
	"Math.LN10",
	"Math.LN2",
	"Math.LOG2E",
	"Math.LOG10E",
	"Math.PI",
	"Math.SQRT1_2",
	"Math.SQRT2",
	"Math.abs",
	"Math.acos",
	"Math.acosh",
	"Math.asin",
	"Math.asinh",
	"Math.atan",
	"Math.atan2",
	"Math.atanh",
	"Math.cbrt",
	"Math.ceil",
	"Math.clz32",
	"Math.cos",
	"Math.cosh",
	"Math.exp",
	"Math.expm1",
	"Math.floor",
	"Math.fround",
	"Math.hypot",
	"Math.imul",
	"Math.log",
	"Math.log10",
	"Math.log1p",
	"Math.log2",
	"Math.max",
	"Math.min",
	"Math.pow",
	"Math.round",
	"Math.sign",
	"Math.sin",
	"Math.sinh",
	"Math.sqrt",
	"Math.tan",
	"Math.tanh",
	"Math.trunc",
	"Math: Math",

	// Number: isInteger, parseFloat, toString, toFixed; and the NaN and Infinity values
	"Number.toString",
	"Number.toFixed",
	"NumberConstructor.isInteger",
	"NumberConstructor.parseFloat",
	"Number: NumberConstructor",
	"NaN: number",
	"Infinity: number",

	// String: the String(x) conversion and the string methods
	"String.length",
	"String.charCodeAt",
	"String.slice",
	"String.indexOf",
	"String.includes",
	"String.split",
	"String.trim",
	"String.toUpperCase",
	"String.toLowerCase",
	"String.startsWith",
	"String.endsWith",
	"String()",

	// The array methods; reduce with and without an initial value
	"Array<T>.length",
	"Array<T>.push",
	"Array<T>.pop",
	"Array<T>.indexOf",
	"Array<T>.includes",
	"Array<T>.slice",
	"Array<T>.join",
	"Array<T>.map<U>",
	"Array<T>.filter",
	"Array<T>.forEach",
	"Array<T>.reduce",
	"Array<T>.reduce<U>",
}

// lib_declarations lists the names the top-level statements of tree declare: `declare const x: T`
// as "x: T", `declare function f` as "f()", and a member of an interface as "Owner<T>.member<U>",
// with type parameters only where they are declared. Any other statement is listed as its dump,
// which no row of LIB_DECLARATIONS matches.
lib_declarations :: proc(tree: ast.File_AST) -> []string {
	nodes := tree.nodes
	entries := make([dynamic]string, context.temp_allocator)
	module := nodes[ast.ROOT].variant.(ast.Module)
	for id in module.statements {
		#partial switch v in nodes[id].variant {
		case ast.Var_Decl:
			if v.modifiers == {.Declare} && v.kind == .Const {
				for declarator_id in v.declarators {
					declarator := nodes[declarator_id].variant.(ast.Declarator)
					type := dump_text(nodes, declarator.type)
					append(&entries, concat(declarator.name.text, ": ", type))
				}
				continue
			}
		case ast.Function_Decl:
			if v.modifiers == {.Declare} {
				append(&entries, concat(v.name.text, "()"))
				continue
			}
		case ast.Interface_Decl:
			if v.modifiers == {} {
				owner := with_type_params(nodes, v.name.text, v.type_params)
				body := nodes[v.body].variant.(ast.Object_Type)
				for member_id in body.members {
					member := nodes[member_id].variant.(ast.Property_Signature)
					name := member.name.text
					if method, is_method := nodes[member.type].variant.(ast.Function_Type);
					   is_method {
						name = with_type_params(nodes, name, method.type_params)
					}
					append(&entries, concat(owner, ".", name))
				}
				continue
			}
		}
		append(&entries, dump_text(nodes, id))
	}
	return entries[:]
}

// dump_text is the dump of one node.
dump_text :: proc(nodes: []ast.Node, id: ast.Node_ID) -> string {
	b := strings.builder_make(context.temp_allocator)
	dump(&b, nodes, id)
	return strings.to_string(b)
}

// with_type_params is name followed by its type parameters, as in "Array<T>"; without any it is
// name.
with_type_params :: proc(nodes: []ast.Node, name: string, type_params: []ast.Node_ID) -> string {
	if len(type_params) == 0 {
		return name
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, name)
	for id, i in type_params {
		strings.write_string(&b, "<" if i == 0 else ", ")
		strings.write_string(&b, nodes[id].variant.(ast.Type_Param).name.text)
	}
	strings.write_string(&b, ">")
	return strings.to_string(b)
}

// sorted_differences walks two sorted lists and returns the entries only want has and the ones
// only got has. A repeated entry counts once per repetition, so a duplicate shows up too.
sorted_differences :: proc(want, got: []string) -> (missing: []string, extra: []string) {
	only_want := make([dynamic]string, context.temp_allocator)
	only_got := make([dynamic]string, context.temp_allocator)
	i, j := 0, 0
	for i < len(want) || j < len(got) {
		switch {
		case j == len(got) || (i < len(want) && want[i] < got[j]):
			append(&only_want, want[i])
			i += 1
		case i == len(want) || got[j] < want[i]:
			append(&only_got, got[j])
			j += 1
		case:
			i += 1
			j += 1
		}
	}
	return only_want[:], only_got[:]
}
