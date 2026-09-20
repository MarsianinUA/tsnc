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

	// T3xxx: types. check (T3.2 on) reports these, the only phase that knows what a type is.
	Type_Mismatch, // {0} is the type of the value, {1} the type it has to fit
	Loose_Equality, // {0} and {1} are the types of the two sides
	Operand_Not_Number, // {0} is the operator: "*", "-"; {1} the type of the operand
	Addition_Operands, // {0} and {1} are the types of the two sides
	Comparison_Operands, // {0} and {1} are the types of the two sides
	Not_Callable, // {0} is the type of the callee
	// {0} is what the function takes: "1 argument", "1 to 3 arguments"; {1} what the call passes
	Argument_Count,
	Missing_Annotation, // {0} is the name
	Assign_To_Const, // {0} is the name
	Recursive_Return_Type, // {0} is the name of the function
	Field_Not_Found, // {0} is the field name, {1} the type that has no such field
	Missing_Field, // {0} is the field name, {1} the type that declares it
	Not_Indexable, // {0} is the type of what `[]` was written after
	Assign_To_Readonly, // {0} is the field name
	Duplicate_Field, // {0} is the field name
	Circular_Type, // {0} is the name of the type alias
	Empty_Array_Literal,
	// {0} is the name of the type, {1} how many arguments it takes: "one type argument"
	Type_Argument_Count,

	// T4xxx: names, modules and imports. bind (T2.7) reports these, driver (T2.8) the three that
	// need a file system to decide, and program (T3.1) the one that needs the whole module graph.
	Redeclared_Name, // {0} is the name
	Duplicate_Export, // {0} is the exported name
	Undeclared_Export, // {0} is the exported name
	Module_Not_Found, // {0} is the specifier as written
	Bare_Specifier, // {0} is the specifier as written
	Module_Unreadable, // {0} is the specifier, {1} why the file could not be read
	Cycle_With_Side_Effects, // {0} lists the modules of the cycle; program (T3.1) reports it
	Cannot_Find_Name, // {0} is the name; check (T3.2) reports it, once it has read the lib module
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
	.Type_Mismatch = {
		number = 3001,
		text = "type `{0}` is not assignable to type `{1}`",
		hint = "change the value to a `{1}`, or widen the declared type so that it covers `{0}` as well",
	},
	.Loose_Equality = {
		number = 3002,
		text = "`==` and `!=` need both sides to have the same type, but these are `{0}` and `{1}`",
		hint = "use `===` or `!==`, which compare without converting; tsnc allows `==` only where it already means `===`",
	},
	.Operand_Not_Number = {
		number = 3003,
		text = "operator `{0}` needs a number, but an operand is `{1}`",
		hint = "convert the operand first, with `Number.parseFloat(s)` for a string, or use `+` if you meant to join text",
	},
	.Addition_Operands = {
		number = 3004,
		text = "`+` cannot add `{0}` and `{1}`",
		hint = "`+` adds two numbers or joins a string with anything; convert one side, or write a template string",
	},
	.Comparison_Operands = {
		number = 3005,
		text = "`{0}` and `{1}` cannot be ordered",
		hint = "`<`, `<=`, `>` and `>=` compare two numbers or two strings; convert one side first",
	},
	.Not_Callable = {
		number = 3006,
		text = "type `{0}` is not callable",
		hint = "call a function or an arrow; check the name, and check that a call earlier in the expression returns one",
	},
	.Argument_Count = {
		number = 3007,
		text = "this call passes {1}, but the function takes {0}",
		hint = "add or remove arguments; a parameter may be left out only where it is written `x?: T`",
	},
	.Missing_Annotation = {
		number = 3008,
		text = "`{0}` needs a type annotation",
		hint = "write the type after the name, as `{0}: number`; a variable can take its type from an initializer instead",
	},
	.Assign_To_Const = {
		number = 3009,
		text = "cannot assign to `{0}`, which is a `const`",
		hint = "declare it with `let` if it has to change, or make a new binding for the new value",
	},
	.Recursive_Return_Type = {
		number = 3010,
		text = "the return type of `{0}` cannot be inferred, because it refers to itself",
		hint = "write the return type after the parameters, as `function {0}(): number`",
	},
	.Field_Not_Found = {
		number = 3011,
		text = "`{0}` is not a field of type `{1}`",
		hint = "check the spelling; an object has exactly the fields its type declares, and none can be added after it is made",
	},
	.Missing_Field = {
		number = 3012,
		text = "this value has no field `{0}`, which type `{1}` declares",
		hint = "add `{0}`; an object literal may leave out a field declared `{0}?: T`, and two types need the same set of fields either way",
	},
	.Not_Indexable = {
		number = 3013,
		text = "type `{0}` cannot be indexed",
		hint = "`x[i]` reads an element of an array or a code unit of a string; read a field with `x.name`",
	},
	.Assign_To_Readonly = {
		number = 3014,
		text = "cannot assign to `{0}`, which is `readonly`",
		hint = "drop `readonly` from the field, or build a new object with the value you want",
	},
	.Duplicate_Field = {
		number = 3015,
		text = "`{0}` appears twice in the same object",
		hint = "remove one of the two; a name holds one field, and two declarations of it do not merge",
	},
	.Circular_Type = {
		number = 3016,
		text = "type `{0}` refers to itself",
		hint = "write it as an `interface`, which may name itself, instead of a `type` alias",
	},
	.Empty_Array_Literal = {
		number = 3017,
		text = "the element type of this empty array cannot be inferred",
		hint = "annotate the variable or the parameter it goes into, as `const xs: number[] = []`",
	},
	.Type_Argument_Count = {
		number = 3018,
		text = "type `{0}` takes {1}",
		hint = "write `Array<T>` with exactly one type argument; a type of your own takes none, because generics of your own arrive in v2",
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
	.Cannot_Find_Name = {
		number = 4008,
		text = "cannot find name `{0}`",
		hint = "declare it before this point, or import it from the module it lives in; tsnc has no globals beyond the declarations of its built-in lib",
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
