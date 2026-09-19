package parse

import "../source"

// Token is one token of a file, as tokenize returns it and parse_tokens reads it.
Token :: struct {
	kind:              Token_Kind,
	// A line terminator lies between the previous token (or the start of the file) and this one,
	// inside a comment too. Automatic semicolon insertion reads it.
	line_break_before: bool,
	// The text of the token with its quotes, backticks, `}` and `${`. EOF is zero-width at the end
	// of the text.
	span:              source.Span,
	value:             Token_Value,
}

// Token_Value is nil for punctuators and EOF.
//
// A string is borrowed from the source text, except a cooked value that differs from its source
// (an escape, a CRLF in a template): tokenize allocates that one.
Token_Value :: union {
	f64, // Number
	// Identifier and reserved words: the name as written. String and the template kinds: the
	// cooked value in UTF-8, in the form of ast.String_Literal.value.
	string,
}

Token_Kind :: enum u8 {
	EOF,

	// Names and literals.
	Identifier, // also the contextual keywords: `type`, `as`, `of`, `from`, `declare`, `number`
	Number,
	String,
	No_Substitution_Template, // `text`
	Template_Head, // `text${
	Template_Middle, // }text${
	Template_Tail, // }text`

	// Punctuators.
	Open_Brace, // {
	Close_Brace, // }
	Open_Paren, // (
	Close_Paren, // )
	Open_Bracket, // [
	Close_Bracket, // ]
	Dot, // .
	Dot_Dot_Dot, // ...
	Semicolon, // ;
	Comma, // ,
	Colon, // :
	Question, // ?
	Question_Dot, // ?.
	Arrow, // =>
	At, // @

	// Operators. `>` is always a Greater of its own, so that `>>` can close two type argument
	// lists: parse_tokens joins touching `>` and `=` tokens into `>=`, `>>`, `>>=`, `>>>` and
	// `>>>=`, as tsc does.
	Plus, // +
	Minus, // -
	Star, // *
	Star_Star, // **
	Slash, // /
	Percent, // %
	Plus_Plus, // ++
	Minus_Minus, // --
	Less, // <
	Less_Equal, // <=
	Less_Less, // <<
	Greater, // >
	Equal_Equal, // ==
	Equal_Equal_Equal, // ===
	Bang_Equal, // !=
	Bang_Equal_Equal, // !==
	Amp, // &
	Amp_Amp, // &&
	Bar, // |
	Bar_Bar, // ||
	Caret, // ^
	Tilde, // ~
	Bang, // !
	Question_Question, // ??

	// Assignments.
	Equal, // =
	Plus_Equal, // +=
	Minus_Equal, // -=
	Star_Equal, // *=
	Star_Star_Equal, // **=
	Slash_Equal, // /=
	Percent_Equal, // %=
	Less_Less_Equal, // <<=
	Amp_Equal, // &=
	Amp_Amp_Equal, // &&=
	Bar_Equal, // |=
	Bar_Bar_Equal, // ||=
	Caret_Equal, // ^=
	Question_Question_Equal, // ??=

	// Reserved words of a module: the ECMAScript reserved words, the ones strict mode adds and
	// `await`. Each is written in lower case: .Instanceof is `instanceof`.
	Await,
	Break,
	Case,
	Catch,
	Class,
	Const,
	Continue,
	Debugger,
	Default,
	Delete,
	Do,
	Else,
	Enum,
	Export,
	Extends,
	False,
	Finally,
	For,
	Function,
	If,
	Implements,
	Import,
	In,
	Instanceof,
	Interface,
	Let,
	New,
	Null,
	Package,
	Private,
	Protected,
	Public,
	Return,
	Static,
	Super,
	Switch,
	This,
	Throw,
	True,
	Try,
	Typeof,
	Var,
	Void,
	While,
	With,
	Yield,
}
