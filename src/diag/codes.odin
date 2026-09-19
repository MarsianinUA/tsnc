package diag

// Code names one kind of compile error. Its number, text and hint live in REGISTRY; the package
// doc has the numbering and wording rules.
Code :: enum u16 {
	// T1xxx: syntax. tokenize (T2.4) and parse (T2.5) report these.
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
	Unsupported_Syntax, // {0} names the construct in the plural: "labels", "intersection types"
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
}
