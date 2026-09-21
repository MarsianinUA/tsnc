/*
The syntax tree of one source file. parse builds a File_AST; bind, check and lower read it and never
change it. A later phase keeps what it learns about a node (its type, the symbol an identifier
refers to) in its own table indexed by the node's Node_ID.

IDs:
- A File_AST keeps every node of the file in one array, and a Node_ID is an index into it, so the
  IDs of a file are dense: 0 ..< len(nodes).
- nodes[ROOT] (index 0) is the Module. The root is never a child, so a child field that holds
  NO_NODE (also 0) means the child is absent: a `let` without an initializer, a `return` without a
  value. A reader of a fact table asserts id != NO_NODE, or it silently reads the root's row.
- No other order is promised. parse reserves index 0 for the root and appends the other nodes as it
  finishes them, children before parents.

Names:
- An Ident node is always a use of a name, which bind resolves.
- The name a declaration introduces, a member name, a property key and an import or export name are
  a Name inside their node, with its own span for diagnostics. They are not nodes.
- When parse recovers from a missing name, the Name has empty text and a zero-width span; later
  phases skip it.

Bad nodes: a Bad node stands for text that parse could not turn into a node, a syntax error or a
construct outside the subset, and parse has reported a diagnostic for it. A Bad node fills only a
statement, expression or type slot. A list of one kind of node (params, type_params, declarators,
cases, specifiers, properties, members) never holds one: parse drops the broken element. Constructs
outside the v1 subset (classes, `try`, destructuring and the other v2 and "never" items of
requirements 2.2) have no node of their own; they parse to Bad.

Memory: parse allocates the node array, every list and every cooked string with its task allocator.
The other Ident and Name texts borrow the source text. Both live until the end of the build.
*/
package ast

import "../source"

Node_ID :: distinct u32

ROOT :: Node_ID(0)

// NO_NODE in a child field means the child is absent. It equals ROOT, which is never a child.
NO_NODE :: Node_ID(0)

File_AST :: struct {
	file:    source.File_ID,
	nodes:   []Node, // indexed by Node_ID; nodes[ROOT] is the Module
	// Every Import_Named, Import_Namespace and Export_Named with `from`, in source order: the
	// module requests that driver follows.
	imports: []Node_ID,
}

Node :: struct {
	span:    source.Span,
	variant: Variant,
}

// Name is a declared or member name. It is not a node; see the package doc.
Name :: struct {
	text: string,
	span: source.Span,
}

// Variant is #no_nil with Bad first, so a zero Node is a Bad node, never an empty union.
Variant :: union #no_nil {
	Bad,
	Module,

	// Declarations and modules.
	Var_Decl,
	Declarator,
	Function_Decl,
	Param,
	Type_Param,
	Interface_Decl,
	Type_Alias_Decl,
	Import_Named,
	Import_Namespace,
	Export_Named,
	Specifier,

	// Statements.
	Block,
	Expr_Stmt,
	If,
	Switch,
	Case,
	For,
	For_Of,
	While,
	Do_While,
	Break,
	Continue,
	Return,
	Empty,

	// Expressions.
	Ident,
	Number_Literal,
	String_Literal,
	Template,
	Bool_Literal,
	Null_Literal,
	Array_Literal,
	Object_Literal,
	Property,
	Arrow,
	Unary,
	Update,
	Binary,
	Assign,
	Conditional,
	Call,
	Member,
	Index,
	As,
	Non_Null,

	// Types.
	Keyword_Type,
	Literal_Type,
	Type_Ref,
	Array_Type,
	Union_Type,
	Function_Type,
	Object_Type,
	Property_Signature,
}

// Bad covers the text parse skipped after reporting it.
Bad :: struct {}

Module :: struct {
	statements: []Node_ID,
}

// Declarations and modules.

Modifier :: enum u8 {
	Export,
	Declare, // `declare`: allowed only in the lib file, check rejects it elsewhere
}

Modifiers :: bit_set[Modifier;u8]

Var_Kind :: enum u8 {
	Let,
	Const,
}

// Var_Decl is `let a = 1, b = 2` or `declare const console: Console`.
Var_Decl :: struct {
	modifiers:   Modifiers,
	kind:        Var_Kind,
	declarators: []Node_ID, // Declarator nodes
}

// Declarator is one `name: type = init` of a Var_Decl.
Declarator :: struct {
	name: Name,
	type: Node_ID, // type slot; NO_NODE without an annotation
	init: Node_ID, // expression slot; NO_NODE without an initializer
}

// Function_Decl is `function name<T>(params): return_type { body }`.
Function_Decl :: struct {
	modifiers:   Modifiers,
	name:        Name,
	type_params: []Node_ID, // Type_Param nodes
	params:      []Node_ID, // Param nodes
	return_type: Node_ID, // type slot; NO_NODE without an annotation
	body:        Node_ID, // a Block; NO_NODE in `declare function`
}

Param_Kind :: enum u8 {
	Required,
	Optional, // `x?: T`
	Rest, // `...xs: T[]`
}

// Param is a parameter of a function, an arrow or a function type.
Param :: struct {
	name: Name,
	type: Node_ID, // type slot; NO_NODE without an annotation (arrow parameters)
	kind: Param_Kind,
}

// Type_Param is `T` in `<T>`. Constraints and defaults are outside the subset.
Type_Param :: struct {
	name: Name,
}

// Interface_Decl is `interface Name<T> { members }`.
Interface_Decl :: struct {
	modifiers:   Modifiers,
	name:        Name,
	type_params: []Node_ID, // Type_Param nodes
	body:        Node_ID, // an Object_Type, so an interface and a type literal read the same
}

// Type_Alias_Decl is `type Name<T> = type`.
Type_Alias_Decl :: struct {
	modifiers:   Modifiers,
	name:        Name,
	type_params: []Node_ID, // Type_Param nodes
	type:        Node_ID, // type slot
}

// Import_Named is `import { a, b as c } from "./m"`, or `import "./m"` with no specifiers.
//
// type_only marks `import type`. Node never loads a module imported only that way, so tsnc must not
// run its top-level code either.
Import_Named :: struct {
	type_only:  bool,
	specifiers: []Node_ID, // Specifier nodes
	path:       Node_ID, // a String_Literal
}

// Import_Namespace is `import * as name from "./m"`.
Import_Namespace :: struct {
	type_only: bool,
	name:      Name,
	path:      Node_ID, // a String_Literal
}

// Export_Named is `export { a, b as c }`, or a re-export with `from "./m"`.
Export_Named :: struct {
	type_only:  bool,
	specifiers: []Node_ID, // Specifier nodes
	path:       Node_ID, // a String_Literal; NO_NODE without `from`
}

// Specifier is `name as alias` in an import or export list; alias is a copy of name without `as`.
// In an import, name is the other module's export and alias the local name; in an export, name is
// the local name and alias the export. type_only marks `{ type A }`.
Specifier :: struct {
	type_only: bool,
	name:      Name,
	alias:     Name,
}

// Statements.

Block :: struct {
	statements: []Node_ID,
}

Expr_Stmt :: struct {
	expr: Node_ID,
}

If :: struct {
	condition:   Node_ID,
	then_branch: Node_ID,
	else_branch: Node_ID, // NO_NODE without `else`
}

Switch :: struct {
	value: Node_ID,
	cases: []Node_ID, // Case nodes
}

Case :: struct {
	value:      Node_ID, // expression slot; NO_NODE for `default`
	statements: []Node_ID,
}

// For is `for (init; condition; update) body`; each of the first three may be NO_NODE.
For :: struct {
	init:      Node_ID, // a Var_Decl or an expression
	condition: Node_ID,
	update:    Node_ID,
	body:      Node_ID,
}

// For_Of is `for (const x of iterable) body`. It always declares its variable: `for (x of xs)`
// over an existing variable is outside the subset.
For_Of :: struct {
	declaration: Node_ID, // a Var_Decl with one Declarator and no initializer
	iterable:    Node_ID,
	body:        Node_ID,
}

While :: struct {
	condition: Node_ID,
	body:      Node_ID,
}

Do_While :: struct {
	body:      Node_ID,
	condition: Node_ID,
}

Break :: struct {}

Continue :: struct {}

Return :: struct {
	value: Node_ID, // NO_NODE in a bare `return`
}

// Empty is a lone `;`.
Empty :: struct {}

// Expressions.

// Ident is a use of a name.
Ident :: struct {
	name: string,
}

Number_Literal :: struct {
	value: f64,
}

// String_Literal holds the cooked value in UTF-8. A lone surrogate escape (`\uD800`) keeps its
// three-byte WTF-8 form, so lower gets back every UTF-16 unit.
String_Literal :: struct {
	value: string,
}

// Template is `a${x}b${y}c`: the cooked parts "a", "b", "c" between the expressions, in the form of
// String_Literal.value. len(parts) == len(expressions) + 1.
Template :: struct {
	parts:       []string,
	expressions: []Node_ID,
}

Bool_Literal :: struct {
	value: bool,
}

Null_Literal :: struct {}

Array_Literal :: struct {
	elements: []Node_ID,
}

Object_Literal :: struct {
	properties: []Node_ID, // Property nodes
}

// Property is `name: value` in an object literal. In the shorthand `{x}`, value is an Ident at the
// same span as name.
Property :: struct {
	name:  Name,
	value: Node_ID,
}

// Arrow is `(params): return_type => body`.
Arrow :: struct {
	params:      []Node_ID, // Param nodes
	return_type: Node_ID, // type slot; NO_NODE without an annotation
	body:        Node_ID, // a Block, or an expression for `x => x * 2`
}

Unary_Op :: enum u8 {
	Minus, // -
	Plus, // +
	Not, // !
	Bit_Not, // ~
	Typeof, // typeof
}

Unary :: struct {
	op:      Unary_Op,
	operand: Node_ID,
}

// Update_Op names `++` and `--` with their position; they are assignments, not Unary operators.
Update_Op :: enum u8 {
	Pre_Increment, // ++x
	Pre_Decrement, // --x
	Post_Increment, // x++
	Post_Decrement, // x--
}

Update :: struct {
	op:      Update_Op,
	operand: Node_ID,
}

Binary_Op :: enum u8 {
	Add, // +
	Subtract, // -
	Multiply, // *
	Divide, // /
	Remainder, // %
	Power, // **
	Shift_Left, // <<
	Shift_Right, // >>
	Shift_Right_Unsigned, // >>>
	Bit_And, // &
	Bit_Or, // |
	Bit_Xor, // ^
	Less, // <
	Less_Equal, // <=
	Greater, // >
	Greater_Equal, // >=
	Equal, // ==
	Not_Equal, // !=
	Strict_Equal, // ===
	Strict_Not_Equal, // !==
	And, // &&
	Or, // ||
	Coalesce, // ??
}

Binary :: struct {
	op:    Binary_Op,
	left:  Node_ID,
	right: Node_ID,
}

// Assign_Op is `=` or a compound assignment, named after its Binary_Op: .Add is `+=`.
Assign_Op :: enum u8 {
	Assign, // =
	Add, // +=
	Subtract, // -=
	Multiply, // *=
	Divide, // /=
	Remainder, // %=
	Power, // **=
	Shift_Left, // <<=
	Shift_Right, // >>=
	Shift_Right_Unsigned, // >>>=
	Bit_And, // &=
	Bit_Or, // |=
	Bit_Xor, // ^=
	And, // &&=
	Or, // ||=
	Coalesce, // ??=
}

Assign :: struct {
	op:     Assign_Op,
	target: Node_ID,
	value:  Node_ID,
}

// Conditional is `condition ? then_value : else_value`.
Conditional :: struct {
	condition:  Node_ID,
	then_value: Node_ID,
	else_value: Node_ID,
}

Call :: struct {
	callee: Node_ID,
	args:   []Node_ID,
}

// Member is `object.name`.
Member :: struct {
	object: Node_ID,
	name:   Name,
}

// Index is `object[index]`.
Index :: struct {
	object: Node_ID,
	index:  Node_ID,
}

// As is `expr as type`.
As :: struct {
	expr: Node_ID,
	type: Node_ID,
}

// Non_Null is `expr!`.
Non_Null :: struct {
	expr: Node_ID,
}

// Types.

Type_Keyword :: enum u8 {
	Number,
	String,
	Boolean,
	Null,
	Undefined,
	Void,
	Any,
	Unknown,
	Never,
}

Keyword_Type :: struct {
	keyword: Type_Keyword,
}

// Literal is the value of a literal type: "circle", 42 or true.
Literal :: union #no_nil {
	f64,
	string,
	bool,
}

// Literal_Type is a literal used as a type. parse folds a leading minus into the value: `-1`.
Literal_Type :: struct {
	value: Literal,
}

// Type_Ref is `Point`, `m.Point` or `Array<T>`.
Type_Ref :: struct {
	qualifier: Name, // `m` in `m.Point`; empty text without one
	name:      Name,
	args:      []Node_ID, // type slots
}

// Array_Type is `T[]`; `Array<T>` is a Type_Ref.
Array_Type :: struct {
	element: Node_ID,
}

// Union_Type is `A | B | C`, flattened.
Union_Type :: struct {
	members: []Node_ID,
}

// Function_Type is `<U>(params) => return_type`, and also the type of a method signature.
Function_Type :: struct {
	type_params: []Node_ID, // Type_Param nodes
	params:      []Node_ID, // Param nodes
	return_type: Node_ID,
}

// Object_Type is `{ members }`, as a type literal or the body of an interface.
Object_Type :: struct {
	members: []Node_ID, // Property_Signature nodes
}

Member_Flag :: enum u8 {
	Optional, // `x?: T`
	Readonly,
}

Member_Flags :: bit_set[Member_Flag;u8]

// Property_Signature is `readonly name?: type`. A method signature `map<U>(f: ...): U[]` is one too,
// with a Function_Type.
Property_Signature :: struct {
	flags: Member_Flags,
	name:  Name,
	type:  Node_ID,
}
