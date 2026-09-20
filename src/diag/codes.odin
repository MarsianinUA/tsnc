package diag

// Code names one kind of compile error. Its number, text and hint live in REGISTRY; the package
// doc has the numbering and wording rules.
Code :: enum u16 {
	// T1xxx: syntax. tokenize (T2.4) and parse (T2.5) report these, and bind (T2.7) the two jumps,
	// which need to know what encloses them.
	Unexpected_Character,
	Unterminated_String,
	Unterminated_Template,
	Unterminated_Comment,
	Invalid_Number,
	Invalid_Escape,
	Expected_Token, // {0} and {1} describe tokens: "`;`", "end of file"
	Unexpected_Token,
	Mixed_Coalesce,
	Unary_Before_Power, // {0} is the operator: "-", "typeof"
	Invalid_Assignment_Target,
	Nesting_Too_Deep,
	Break_Outside_Loop,
	Continue_Outside_Loop,

	// T2xxx: constructs outside the subset, which parse reports: the syntactic "never" rules of
	// requirements 2.2, then the v2 and other non-v1 constructs.
	Var_Declaration,
	With_Statement,
	Namespace,
	Decorator,
	Arguments_Object,
	Delete_Operator,
	Eval,
	New_Function,
	Class,
	New_Expression,
	Exception, // {0}: "try", "throw"
	Async,
	Enum,
	Destructuring,
	Spread,
	Optional_Chaining,
	Default_Export,
	Function_Expression, // {0}: "function expressions", "object literal methods"
	For_In,
	Regular_Expression,
	Unsupported_Syntax, // {0} is construct_text of a Construct: "labels", "intersection types"

	// T4xxx: names, modules and imports. bind (T2.7) reports these, driver (T2.8) the three that
	// need a file system to decide, and program (T3.1) the one that needs the whole module graph.
	Redeclared_Name, // {0} is the name
	Duplicate_Export, // {0} is the exported name
	Undeclared_Export, // {0} is the exported name
	Module_Not_Found, // {0} is the specifier as written
	Bare_Specifier, // {0} is the specifier as written
	Module_Unreadable, // {0} is the specifier, {1} why the file could not be read
	Cycle_With_Side_Effects, // {0} lists the modules of the cycle; program (T3.1) reports it
}

@(private)
Row :: struct {
	number: u16, // printed as T<number>; within 1000..9999, so always four digits
	text:   string,
	hint:   string, // how to rewrite the code so that tsnc accepts it
}

// REGISTRY must have a row for every Code: the literal has no #partial, so a code without a row
// does not compile.
@(private, rodata)
REGISTRY := [Code]Row {
	.Unexpected_Character = {
		number = 1001,
		text = "unexpected character `{0}`",
		hint = "remove the character, or put it inside a string or a comment",
	},
	.Unterminated_String = {
		number = 1002,
		text = "unterminated string literal",
		hint = "close the string with its opening quote on the same line; use a template literal for text across lines",
	},
	.Unterminated_Template = {
		number = 1003,
		text = "unterminated template literal",
		hint = "close the template with a backtick and every `${` with `}`",
	},
	.Unterminated_Comment = {
		number = 1004,
		text = "unterminated block comment",
		hint = "close the comment with `*/`",
	},
	.Invalid_Number = {
		number = 1005,
		text = "invalid number literal",
		hint = "write digits after `0x`, `0o`, `0b` and `e`, put `_` only between digits, write `0o17` instead of `017`, and separate the number from the name after it",
	},
	.Invalid_Escape = {
		number = 1006,
		text = "invalid escape sequence `{0}`",
		hint = "use an escape such as `\\n`, `\\t`, `\\x41`, `\\u0041` or `\\u{1F600}`, or write `\\\\` for a backslash",
	},
	.Expected_Token = {
		number = 1007,
		text = "expected {0}, found {1}",
		hint = "add {0} here, or look before this point for an unclosed bracket or a missing operator",
	},
	.Unexpected_Token = {
		number = 1008,
		text = "unexpected {0}",
		hint = "look before this point for an unclosed bracket or a missing operator or comma",
	},
	.Mixed_Coalesce = {
		number = 1009,
		text = "`??` cannot be mixed with `&&` or `||` without parentheses",
		hint = "add parentheses: `(a ?? b) || c` or `a ?? (b || c)`",
	},
	.Unary_Before_Power = {
		number = 1010,
		text = "the left side of `**` cannot be a unary `{0}` expression",
		hint = "add parentheses: `(-x) ** 2` or `-(x ** 2)`",
	},
	.Invalid_Assignment_Target = {
		number = 1011,
		text = "cannot assign to this expression",
		hint = "assign to a variable, a field such as `obj.x` or an element such as `arr[i]`",
	},
	.Nesting_Too_Deep = {
		number = 1012,
		text = "the code nests too deeply",
		hint = "move inner expressions into variables and inner blocks into functions of their own",
	},
	.Break_Outside_Loop = {
		number = 1013,
		text = "`break` is not inside a loop or a `switch`",
		hint = "remove the `break`, or use `return` to leave a function; a loop does not reach into a function written inside it",
	},
	.Continue_Outside_Loop = {
		number = 1014,
		text = "`continue` is not inside a loop",
		hint = "remove the `continue`, or use `return` to end this call of a callback; a `switch` takes `break` but not `continue`",
	},
	.Var_Declaration = {
		number = 2001,
		text = "`var` is not supported",
		hint = "use `let`, or `const` for a variable that is never reassigned",
	},
	.With_Statement = {
		number = 2002,
		text = "`with` is not supported",
		hint = "name the object in every access: `obj.x` instead of `x` inside `with (obj)`",
	},
	.Namespace = {
		number = 2003,
		text = "`namespace` is not supported",
		hint = "move the declarations into their own module, export them and import them where they are used",
	},
	.Decorator = {
		number = 2004,
		text = "decorators are not supported",
		hint = "call the decorator function explicitly: `const f = logged(g)` instead of `@logged`",
	},
	.Arguments_Object = {
		number = 2005,
		text = "`arguments` is not supported",
		hint = "declare every parameter by name and use the names",
	},
	.Delete_Operator = {
		number = 2006,
		text = "`delete` is not supported",
		hint = "an object keeps its fields: declare the field optional (`x?: T`) and assign `undefined` instead",
	},
	.Eval = {
		number = 2007,
		text = "`eval` is not supported",
		hint = "write the code in the source: tsnc compiles ahead of time and cannot run a string as code",
	},
	.New_Function = {
		number = 2008,
		text = "`new Function` is not supported",
		hint = "write the function in the source: `(a, b) => a + b` instead of `new Function(\"a\", \"b\", \"return a + b\")`",
	},
	.Class = {
		number = 2009,
		text = "classes, `this` and `super` are not supported",
		hint = "describe the shape with an `interface` and write the methods as functions that take the object as a parameter",
	},
	.New_Expression = {
		number = 2010,
		text = "`new` is not supported",
		hint = "create objects with object literals such as `{ x: 1 }` and arrays with array literals such as `[1, 2]`",
	},
	.Exception = {
		number = 2011,
		text = "`{0}` is not supported",
		hint = "return an error value, or print the error with `console.error` and call `process.exit(1)`",
	},
	.Async = {
		number = 2012,
		text = "`async` and `await` are not supported",
		hint = "call the functions synchronously and use their results directly",
	},
	.Enum = {
		number = 2013,
		text = "`enum` is not supported",
		hint = "use a union of literal types: `type Color = \"red\" | \"green\"`",
	},
	.Destructuring = {
		number = 2014,
		text = "destructuring is not supported",
		hint = "read each field or element on its own: `const x = point.x`",
	},
	.Spread = {
		number = 2015,
		text = "spread `...` is not supported",
		hint = "pass the values one by one, or build the array with `push` in a loop",
	},
	.Optional_Chaining = {
		number = 2016,
		text = "optional chaining `?.` is not supported",
		hint = "check for `null` or `undefined` first: `x === undefined ? undefined : x.y`",
	},
	.Default_Export = {
		number = 2017,
		text = "default exports and imports are not supported",
		hint = "use a named export and import: `export function f` and `import { f } from \"./m\"`",
	},
	.Function_Expression = {
		number = 2018,
		text = "{0} are not supported",
		hint = "use an arrow function such as `(x) => x + 1`, or declare the function by name",
	},
	.For_In = {
		number = 2019,
		text = "`for...in` is not supported",
		hint = "loop over an array with `for...of`, or read the fields by name",
	},
	.Regular_Expression = {
		number = 2020,
		text = "regular expressions are not supported",
		hint = "use string methods such as `indexOf`, `includes`, `split` or `startsWith`",
	},
	.Unsupported_Syntax = {
		number = 2021,
		text = "{0} are not supported",
		hint = "rewrite the code without them: tsnc supports the TypeScript subset listed in its requirements, section 2.2",
	},
	.Redeclared_Name = {
		number = 4001,
		text = "`{0}` is already declared in this scope",
		hint = "rename one of the declarations; one name holds at most one value and one type, and two interfaces of one name do not merge",
	},
	.Duplicate_Export = {
		number = 4002,
		text = "`{0}` is exported more than once",
		hint = "export the name once, or rename one of the exports: `export { a as other }`",
	},
	.Undeclared_Export = {
		number = 4003,
		text = "`{0}` is not declared in this module",
		hint = "declare `{0}` at the top level of this module, or re-export it from the module it comes from: `export { {0} } from \"./m\"`",
	},
	.Module_Not_Found = {
		number = 4004,
		text = "cannot find module `{0}`",
		hint = "create the file, or fix the path: it is relative to the module it is written in, and `./m` and `./m.ts` both name `m.ts`",
	},
	.Bare_Specifier = {
		number = 4005,
		text = "cannot import `{0}`: only relative paths are supported",
		hint = "write a relative path such as `./m`; tsnc reads no `node_modules`, so a package name never names a file",
	},
	.Module_Unreadable = {
		number = 4006,
		text = "cannot read module `{0}`: {1}",
		hint = "check that the path names a file and not a directory, and that the file can be read",
	},
	.Cycle_With_Side_Effects = {
		number = 4007,
		text = "import cycle between modules with top-level side effects: {0}",
		hint = "move what these modules share into a third one, or take the top-level code out of them: a cycle is allowed as long as no module in it runs anything when it loads",
	},
}

// Construct names a construct outside the subset that has no code of its own: Unsupported_Syntax
// reports it, with construct_text as the argument. When a later version supports a construct, its
// name goes away here and the compiler points at every place that reported it.
Construct :: enum u8 {
	// Declarations, statements and modules.
	Function_Overloads,
	Generators,
	Interface_Extends_Clauses,
	Default_Parameter_Values,
	This_Parameters,
	Labels,
	Debugger_Statements,
	For_Of_Without_Declaration,
	Import_Equals_Aliases,
	Import_Attributes,
	Export_Star_Declarations,
	Export_Assignments,
	Export_Import_Aliases,
	String_Specifiers,

	// Expressions.
	Comma_Operators,
	As_Const_Assertions,
	Satisfies_Expressions,
	In_Expressions,
	Instanceof_Expressions,
	Void_Expressions,
	Generic_Arrow_Functions,
	Angle_Bracket_Assertions,
	Tagged_Templates,
	Explicit_Type_Arguments,
	Import_Expressions,
	New_Target,
	Array_Holes,
	Computed_Property_Names,
	Number_Property_Keys,
	Getters_And_Setters,

	// Types.
	Conditional_Types,
	Intersection_Types,
	Indexed_Access_Types,
	Tuple_Types,
	Template_Literal_Types,
	Typeof_Types,
	This_Types,
	Constructor_Types,
	Keyof_Types,
	Readonly_Array_Types,
	Unique_Symbol_Types,
	Infer_Types,
	Object_Symbol_Bigint_Types,
	Type_Predicates,
	Deep_Qualified_Names,
	Type_Parameter_Constraints,
	Type_Parameter_Defaults,
	Index_Signatures,
	Call_Signatures,
	Construct_Signatures,
}

// construct_text is the text of c in the plural, which Unsupported_Syntax puts in place of {0}:
// "labels are not supported".
construct_text :: proc(c: Construct) -> string {
	return CONSTRUCT_TEXTS[c]
}

// CONSTRUCT_TEXTS must have a text for every Construct, as REGISTRY has a row for every Code. The
// texts follow the wording rules of the package doc.
@(private, rodata)
CONSTRUCT_TEXTS := [Construct]string {
	.Function_Overloads         = "function overloads",
	.Generators                 = "generators",
	.Interface_Extends_Clauses  = "interface `extends` clauses",
	.Default_Parameter_Values   = "default parameter values",
	.This_Parameters            = "`this` parameters",
	.Labels                     = "labels",
	.Debugger_Statements        = "`debugger` statements",
	.For_Of_Without_Declaration = "`for...of` loops over an existing variable",
	.Import_Equals_Aliases      = "`import =` aliases",
	.Import_Attributes          = "import attributes",
	.Export_Star_Declarations   = "`export *` declarations",
	.Export_Assignments         = "`export =` assignments",
	.Export_Import_Aliases      = "`export import` aliases",
	.String_Specifiers          = "string import and export names",
	.Comma_Operators            = "comma operators",
	.As_Const_Assertions        = "`as const` assertions",
	.Satisfies_Expressions      = "`satisfies` expressions",
	.In_Expressions             = "`in` expressions",
	.Instanceof_Expressions     = "`instanceof` expressions",
	.Void_Expressions           = "`void` expressions",
	.Generic_Arrow_Functions    = "generic arrow functions",
	.Angle_Bracket_Assertions   = "`<T>` type assertions",
	.Tagged_Templates           = "tagged templates",
	.Explicit_Type_Arguments    = "explicit type arguments",
	.Import_Expressions         = "`import()` and `import.meta` expressions",
	.New_Target                 = "`new.target` expressions",
	.Array_Holes                = "array holes",
	.Computed_Property_Names    = "computed property names",
	.Number_Property_Keys       = "number property keys",
	.Getters_And_Setters        = "getters and setters",
	.Conditional_Types          = "conditional types",
	.Intersection_Types         = "intersection types",
	.Indexed_Access_Types       = "indexed access types",
	.Tuple_Types                = "tuple types",
	.Template_Literal_Types     = "template literal types",
	.Typeof_Types               = "`typeof` types",
	.This_Types                 = "`this` types",
	.Constructor_Types          = "constructor types",
	.Keyof_Types                = "`keyof` types",
	.Readonly_Array_Types       = "`readonly` array types",
	.Unique_Symbol_Types        = "`unique symbol` types",
	.Infer_Types                = "`infer` types",
	.Object_Symbol_Bigint_Types = "`object`, `symbol` and `bigint` types",
	.Type_Predicates            = "type predicates",
	.Deep_Qualified_Names       = "qualified names deeper than `m.T`",
	.Type_Parameter_Constraints = "type parameter constraints",
	.Type_Parameter_Defaults    = "type parameter defaults",
	.Index_Signatures           = "index signatures",
	.Call_Signatures            = "call signatures",
	.Construct_Signatures       = "construct signatures",
}
