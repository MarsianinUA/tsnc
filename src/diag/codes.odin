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

	// T2xxx: constructs outside the subset. These are the syntactic "never" rules of
	// requirements 2.2; parse reports them.
	Var_Declaration,
	With_Statement,
	Namespace,
	Decorator,
	Arguments_Object,
	Delete_Operator,
	Eval,
	New_Function,
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
}
