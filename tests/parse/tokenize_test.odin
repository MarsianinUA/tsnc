package parse_tests

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/diag"
import "../../src/parse"
import "../../src/source"

Expected_Diagnostic :: struct {
	code:  diag.Code,
	start: i32,
	end:   i32,
	arg:   string,
}

@(test)
every_punctuator_has_its_kind :: proc(t: ^testing.T) {
	expect_kinds(
		t,
		"{ } ( ) [ ] . ... ; , : ? ?. => @ " +
		"+ - * ** / % ++ -- < <= << > == === != !== & && | || ^ ~ ! ?? " +
		"= += -= *= **= /= %= <<= &= &&= |= ||= ^= ??=",
		{
			.Open_Brace,
			.Close_Brace,
			.Open_Paren,
			.Close_Paren,
			.Open_Bracket,
			.Close_Bracket,
			.Dot,
			.Dot_Dot_Dot,
			.Semicolon,
			.Comma,
			.Colon,
			.Question,
			.Question_Dot,
			.Arrow,
			.At,
			.Plus,
			.Minus,
			.Star,
			.Star_Star,
			.Slash,
			.Percent,
			.Plus_Plus,
			.Minus_Minus,
			.Less,
			.Less_Equal,
			.Less_Less,
			.Greater,
			.Equal_Equal,
			.Equal_Equal_Equal,
			.Bang_Equal,
			.Bang_Equal_Equal,
			.Amp,
			.Amp_Amp,
			.Bar,
			.Bar_Bar,
			.Caret,
			.Tilde,
			.Bang,
			.Question_Question,
			.Equal,
			.Plus_Equal,
			.Minus_Equal,
			.Star_Equal,
			.Star_Star_Equal,
			.Slash_Equal,
			.Percent_Equal,
			.Less_Less_Equal,
			.Amp_Equal,
			.Amp_Amp_Equal,
			.Bar_Equal,
			.Bar_Bar_Equal,
			.Caret_Equal,
			.Question_Question_Equal,
		},
	)
}

@(test)
the_longest_punctuator_wins :: proc(t: ^testing.T) {
	expect_kinds(
		t,
		"a**=b??=c&&=d||=e<<=f!==g===h...i=>j",
		{
			.Identifier,
			.Star_Star_Equal,
			.Identifier,
			.Question_Question_Equal,
			.Identifier,
			.Amp_Amp_Equal,
			.Identifier,
			.Bar_Bar_Equal,
			.Identifier,
			.Less_Less_Equal,
			.Identifier,
			.Bang_Equal_Equal,
			.Identifier,
			.Equal_Equal_Equal,
			.Identifier,
			.Dot_Dot_Dot,
			.Identifier,
			.Arrow,
			.Identifier,
		},
	)
	expect_kinds(t, "a+++b", {.Identifier, .Plus_Plus, .Plus, .Identifier})
}

// parse_tokens joins touching `>` and `=` tokens, so a `>>` can also close two type argument lists.
@(test)
greater_is_always_one_token :: proc(t: ^testing.T) {
	tokens := expect_kinds(
		t,
		"a>>>=b",
		{.Identifier, .Greater, .Greater, .Greater, .Equal, .Identifier},
	)
	for i in 1 ..< 4 {
		testing.expectf(
			t,
			tokens[i].span.end == tokens[i + 1].span.start,
			"token %d ends at %d, the next starts at %d",
			i,
			tokens[i].span.end,
			tokens[i + 1].span.start,
		)
	}
	expect_kinds(
		t,
		"Array<Array<number>>",
		{.Identifier, .Less, .Identifier, .Less, .Identifier, .Greater, .Greater},
	)
}

@(test)
question_dot_before_a_digit_is_a_conditional :: proc(t: ^testing.T) {
	expect_kinds(t, "a?.5:b", {.Identifier, .Question, .Number, .Colon, .Identifier})
	expect_kinds(t, "a?.b", {.Identifier, .Question_Dot, .Identifier})
}

@(test)
every_reserved_word_has_its_kind :: proc(t: ^testing.T) {
	// The reserved words close Token_Kind, from .Await on.
	for kind in parse.Token_Kind {
		if kind < .Await {
			continue
		}
		// The spelling is the kind in lower case: .Instanceof is `instanceof`.
		word := strings.to_lower(fmt.tprint(kind), context.temp_allocator)
		tokens := expect_kinds(t, word, {kind})
		testing.expect_value(t, tokens[0].value.(string), word)
	}
}

@(test)
names_keep_their_text :: proc(t: ^testing.T) {
	// Contextual keywords are names; parse_tokens tells them apart by their text.
	words := []string {
		"type",
		"of",
		"as",
		"from",
		"declare",
		"number",
		"undefined",
		"$a",
		"_b",
		"x1",
		"\u043f\u0440\u0438", // Cyrillic
		"cafe\u0301", // a combining accent continues a name
	}
	for word in words {
		tokens := expect_kinds(t, word, {.Identifier})
		testing.expect_value(t, tokens[0].value.(string), word)
	}
}

@(test)
numbers_have_their_values :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		value: f64,
	} {
		{"0", 0},
		{"42", 42},
		{"1e21", 1e21},
		{"1E+21", 1e21},
		{"1.5e-7", 1.5e-7},
		{"0.0000001", 1e-7},
		{"0.1", 0.1},
		{".5", 0.5},
		{"5.", 5},
		{"1.e2", 100},
		{"0x10", 16},
		{"0XfF", 255},
		{"0o17", 15},
		{"0b101", 5},
		{"1_000_000", 1e6},
		{"0x1_0", 16},
		{"1e1_0", 1e10},
		// 2^53 + 1 rounds to even, 2^64 - 1 rounds up.
		{"9007199254740993", 9007199254740992},
		{"0xFFFFFFFFFFFFFFFF", 18446744073709551616},
		{"1e400", math.inf_f64(1)},
		// An exponent in the twenties, where strconv.parse_f64 rounds twice and lands a unit in
		// the last place low. Odin folds the constants on the right exactly, so they are the
		// values Node reads. A literal that misses here compiles into a program that prints the
		// wrong digits.
		{"3.14159265e41", 3.14159265e41},
		{"6.02214076e44", 6.02214076e44},
		{"1278572e37", 1278572e37},
	}
	for c in cases {
		tokens := expect_kinds(t, c.text, {.Number})
		testing.expectf(
			t,
			tokens[0].value.(f64) == c.value,
			"%q: got %v, want %v",
			c.text,
			tokens[0].value,
			c.value,
		)
	}
}

@(test)
a_malformed_number_is_one_token_and_one_diagnostic :: proc(t: ^testing.T) {
	literals := []string {
		"0x", // no digits after the prefix
		"0x_1",
		"0b2",
		"1e", // no exponent digits
		"1e+",
		"1_", // `_` not between two digits
		"1__0",
		"1_.5",
		"1._5",
		"0_1",
		"010", // legacy octal
		"08",
		"3in", // a name glued to the number
		"10n",
	}
	for literal in literals {
		text := strings.concatenate({literal, " x"}, context.temp_allocator)
		tokens, diagnostics := tokenize(text)
		expect_token_kinds(t, text, tokens, {.Number, .Identifier})
		expect_diagnostics(t, text, diagnostics, {{.Invalid_Number, 0, i32(len(literal)), ""}})
	}
}

@(test)
strings_have_their_cooked_values :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		value: string,
	} {
		{`'a'`, "a"},
		{`"b"`, "b"},
		{`''`, ""},
		{`"it's"`, "it's"},
		{`'\b\f\n\r\t\v\0'`, "\b\f\n\r\t\v\x00"},
		{`'\'\"\\'`, `'"\`},
		{`'\x41\u0042\u{43}'`, "ABC"},
		// Any other character after a backslash is itself.
		{`'\a\$\q'`, "a$q"},
		// A code point above U+FFFF, directly and as a surrogate pair.
		{`'\u{1F600}'`, "\U0001F600"},
		{`'\uD83D\uDE00'`, "\U0001F600"},
		{`'\u{D83D}\u{DE00}'`, "\U0001F600"},
		// A lone surrogate keeps its WTF-8 form.
		{`'\uD800x'`, "\xED\xA0\x80x"},
		{`'\uDE00\uD83D'`, "\xED\xB8\x80\xED\xA0\xBD"},
		// Line continuations add nothing.
		{"'a\\\nb'", "ab"},
		{"'a\\\r\nb'", "ab"},
		{"'a\x5c\u2028b'", "ab"},
		// U+2028 and U+2029 may stand in a string as they are.
		{"'a\u2028b'", "a\u2028b"},
	}
	for c in cases {
		tokens := expect_kinds(t, c.text, {.String})
		testing.expectf(
			t,
			tokens[0].value.(string) == c.value,
			"%s: got %q, want %q",
			c.text,
			tokens[0].value,
			c.value,
		)
	}
}

@(test)
a_value_without_escapes_borrows_the_text :: proc(t: ^testing.T) {
	text := "'\u043f\u0440\u0438'"
	tokens := expect_kinds(t, text, {.String})
	value := tokens[0].value.(string)
	testing.expect(t, raw_data(value) == &raw_data(text)[1], "the value was copied")
	testing.expect_value(t, value, "\u043f\u0440\u0438")
}

@(test)
an_invalid_escape_is_reported_and_the_string_goes_on :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:   string,
		escape: string,
	} {
		{`'\x4'`, `\x4`},
		{`'\xg'`, `\x`},
		{`'\u12'`, `\u12`},
		{`'\u{}'`, `\u{}`},
		{`'\u{12'`, `\u{12`},
		{`'\u{110000}'`, `\u{110000}`},
		{`'\01'`, `\01`}, // octal escapes are not allowed in strict mode
		{`'\1'`, `\1`},
		{`'\8'`, `\8`},
	}
	for c in cases {
		tokens, diagnostics := tokenize(c.text)
		expect_token_kinds(t, c.text, tokens, {.String})
		end := 1 + i32(len(c.escape))
		expect_diagnostics(t, c.text, diagnostics, {{.Invalid_Escape, 1, end, c.escape}})
	}
}

@(test)
a_string_ends_at_the_end_of_its_line :: proc(t: ^testing.T) {
	text := "let s = 'abc\nlet n = 1"
	tokens, diagnostics := tokenize(text)
	expect_token_kinds(
		t,
		text,
		tokens,
		{.Let, .Identifier, .Equal, .String, .Let, .Identifier, .Equal, .Number},
	)
	expect_diagnostics(t, text, diagnostics, {{.Unterminated_String, 8, 12, ""}})
	testing.expect_value(t, tokens[3].value.(string), "abc")
	testing.expect(t, tokens[4].line_break_before, "the next line starts a new token")

	text = "x = 'abc"
	tokens, diagnostics = tokenize(text)
	expect_token_kinds(t, text, tokens, {.Identifier, .Equal, .String})
	expect_diagnostics(t, text, diagnostics, {{.Unterminated_String, 4, 8, ""}})
}

@(test)
templates_split_into_parts :: proc(t: ^testing.T) {
	expect_template(t, "`abc`", {{.No_Substitution_Template, 0, 5, "abc"}})
	expect_template(
		t,
		"`a${x}b${y}c`",
		{
			{.Template_Head, 0, 4, "a"},
			{.Identifier, 4, 5, "x"},
			{.Template_Middle, 5, 9, "b"},
			{.Identifier, 9, 10, "y"},
			{.Template_Tail, 10, 13, "c"},
		},
	)
}

@(test)
templates_nest :: proc(t: ^testing.T) {
	expect_template(
		t,
		"`a${`b${c}d`}e`",
		{
			{.Template_Head, 0, 4, "a"},
			{.Template_Head, 4, 8, "b"},
			{.Identifier, 8, 9, "c"},
			{.Template_Tail, 9, 12, "d"},
			{.Template_Tail, 12, 15, "e"},
		},
	)
	// The braces of an object literal inside a substitution do not end it.
	tokens := expect_kinds(
		t,
		"`${ {a: {}}.a }`",
		{
			.Template_Head,
			.Open_Brace,
			.Identifier,
			.Colon,
			.Open_Brace,
			.Close_Brace,
			.Close_Brace,
			.Dot,
			.Identifier,
			.Template_Tail,
		},
	)
	testing.expect_value(t, tokens[9].value.(string), "")
}

@(test)
template_text_is_cooked :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		value: string,
	} {
		{"`$ \\${x} $`", "$ ${x} $"},
		{"`\\u0041\\``", "A`"},
		{"`a\r\nb\rc\nd`", "a\nb\nc\nd"},
		{"`a\\\r\nb`", "ab"},
	}
	for c in cases {
		tokens := expect_kinds(t, c.text, {.No_Substitution_Template})
		testing.expectf(
			t,
			tokens[0].value.(string) == c.value,
			"%q: got %q, want %q",
			c.text,
			tokens[0].value,
			c.value,
		)
	}
	// A line break inside a template is part of the token, not a break before the next one.
	tokens := expect_kinds(t, "`a\nb` c", {.No_Substitution_Template, .Identifier})
	testing.expect(t, !tokens[1].line_break_before, "the template's line break leaked out")
}

@(test)
an_unterminated_template_runs_to_the_end_of_the_text :: proc(t: ^testing.T) {
	text := "`abc\nx"
	tokens, diagnostics := tokenize(text)
	expect_token_kinds(t, text, tokens, {.No_Substitution_Template})
	expect_diagnostics(t, text, diagnostics, {{.Unterminated_Template, 0, 6, ""}})

	text = "`a${b}c"
	tokens, diagnostics = tokenize(text)
	expect_token_kinds(t, text, tokens, {.Template_Head, .Identifier, .Template_Tail})
	expect_diagnostics(t, text, diagnostics, {{.Unterminated_Template, 5, 7, ""}})

	// An unclosed substitution is the parser's `expected }`, not a tokenizer error.
	text = "`a${b"
	tokens, diagnostics = tokenize(text)
	expect_token_kinds(t, text, tokens, {.Template_Head, .Identifier})
	expect_diagnostics(t, text, diagnostics, {})
}

@(test)
comments_make_no_tokens :: proc(t: ^testing.T) {
	text := "a /* c"
	tokens, diagnostics := tokenize(text)
	expect_token_kinds(t, text, tokens, {.Identifier})
	expect_diagnostics(t, text, diagnostics, {{.Unterminated_Comment, 2, 6, ""}})

	tokens = expect_kinds(t, "a // c\nb", {.Identifier, .Identifier})
	testing.expect(t, tokens[1].line_break_before, "a line comment ends at a line break")

	tokens = expect_kinds(t, "a /* c */ b", {.Identifier, .Identifier})
	testing.expect(t, !tokens[1].line_break_before, "a one-line block comment is no line break")

	tokens = expect_kinds(t, "a /* c\n */ b", {.Identifier, .Identifier})
	testing.expect(t, tokens[1].line_break_before, "a block comment across lines is a line break")

	// A hashbang line is a comment only at the very start.
	tokens = expect_kinds(t, "#!/usr/bin/env node\nx", {.Identifier})
	testing.expect(t, tokens[0].line_break_before, "the hashbang line ends at a line break")

	text = "x #!y"
	tokens, diagnostics = tokenize(text)
	expect_token_kinds(t, text, tokens, {.Identifier, .Bang, .Identifier})
	expect_diagnostics(t, text, diagnostics, {{.Unexpected_Character, 2, 3, "#"}})
}

@(test)
line_breaks_are_flagged_for_asi :: proc(t: ^testing.T) {
	breaks := []string{"\n", "\r\n", "\r", "\u2028", "\u2029", " \n\t "}
	for line_break in breaks {
		text := strings.concatenate({"a", line_break, "b"}, context.temp_allocator)
		tokens := expect_kinds(t, text, {.Identifier, .Identifier})
		testing.expectf(t, tokens[1].line_break_before, "%q: b has no line break before it", text)
		testing.expectf(t, !tokens[0].line_break_before, "%q: a has a line break before it", text)
	}

	tokens := expect_kinds(t, "a b", {.Identifier, .Identifier})
	testing.expect(t, !tokens[1].line_break_before, "a space is not a line break")

	tokens = expect_kinds(t, "a\n", {.Identifier})
	testing.expect(t, tokens[1].line_break_before, "the EOF after a trailing line break")
}

@(test)
spans_cover_the_token_text_and_eof_is_empty :: proc(t: ^testing.T) {
	tokens, diagnostics := parse.tokenize("ab + 'c'", 3, context.temp_allocator)
	testing.expect_value(t, len(diagnostics), 0)
	expected := []source.Span {
		{file = 3, start = 0, end = 2},
		{file = 3, start = 3, end = 4},
		{file = 3, start = 5, end = 8},
		{file = 3, start = 8, end = 8},
	}
	spans := make([]source.Span, len(tokens), context.temp_allocator)
	for token, i in tokens {
		spans[i] = token.span
	}
	testing.expectf(t, slice.equal(spans, expected), "spans %v", spans)
	testing.expect_value(t, tokens[len(tokens) - 1].kind, parse.Token_Kind.EOF)

	tokens, diagnostics = tokenize("")
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, tokens[0].kind, parse.Token_Kind.EOF)
	testing.expect_value(t, tokens[0].span, source.Span{})
}

@(test)
an_unknown_character_is_reported_and_skipped :: proc(t: ^testing.T) {
	// `#` and the currency sign U+00A4 are not TypeScript tokens; `@` is, for decorators.
	text := "let a = 1 # 2 \u00a4 3 @x"
	tokens, diagnostics := tokenize(text)
	expect_token_kinds(
		t,
		text,
		tokens,
		{.Let, .Identifier, .Equal, .Number, .Number, .Number, .At, .Identifier},
	)
	expect_diagnostics(
		t,
		text,
		diagnostics,
		{{.Unexpected_Character, 10, 11, "#"}, {.Unexpected_Character, 14, 16, "\u00a4"}},
	)

	// A name cannot use `\u` escapes.
	text = "\\u0061"
	tokens, diagnostics = tokenize(text)
	expect_token_kinds(t, text, tokens, {.Identifier})
	expect_diagnostics(t, text, diagnostics, {{.Unexpected_Character, 0, 1, "\\"}})
}

@(test)
unicode_spaces_are_skipped :: proc(t: ^testing.T) {
	tokens := expect_kinds(
		t,
		"a\u00a0b\xef\xbb\xbfc\u3000d\ve\ff",
		{.Identifier, .Identifier, .Identifier, .Identifier, .Identifier, .Identifier},
	)
	for token in tokens {
		testing.expect(t, !token.line_break_before, "a space is not a line break")
	}
}

Expected_Token :: struct {
	kind:  parse.Token_Kind,
	start: i32,
	end:   i32,
	value: string,
}

// expect_template checks the kind, span and string value of every token of text.
expect_template :: proc(
	t: ^testing.T,
	text: string,
	expected: []Expected_Token,
	loc := #caller_location,
) {
	tokens, diagnostics := tokenize(text)
	expect_diagnostics(t, text, diagnostics, {}, loc)
	if !testing.expectf(
		t,
		len(tokens) == len(expected) + 1,
		"%q: %d tokens, want %d",
		text,
		len(tokens) - 1,
		len(expected),
		loc = loc,
	) {
		return
	}
	for e, i in expected {
		token := tokens[i]
		got := Expected_Token{token.kind, token.span.start, token.span.end, token.value.(string)}
		testing.expectf(t, got == e, "%q: token %d is %v, want %v", text, i, got, e, loc = loc)
	}
}

// expect_kinds checks that text has no diagnostics and returns its tokens, EOF included.
expect_kinds :: proc(
	t: ^testing.T,
	text: string,
	expected: []parse.Token_Kind,
	loc := #caller_location,
) -> []parse.Token {
	tokens, diagnostics := tokenize(text)
	expect_diagnostics(t, text, diagnostics, {}, loc)
	expect_token_kinds(t, text, tokens, expected, loc)
	return tokens
}

// expect_token_kinds checks the kinds of tokens, which must end with EOF, the one kind expected
// leaves out.
expect_token_kinds :: proc(
	t: ^testing.T,
	text: string,
	tokens: []parse.Token,
	expected: []parse.Token_Kind,
	loc := #caller_location,
) {
	kinds := make([]parse.Token_Kind, len(tokens), context.temp_allocator)
	for token, i in tokens {
		kinds[i] = token.kind
	}
	ends_with_eof := len(kinds) > 0 && kinds[len(kinds) - 1] == .EOF
	is_expected := ends_with_eof && slice.equal(kinds[:len(kinds) - 1], expected)
	testing.expectf(
		t,
		is_expected,
		"%q: kinds %v, want %v and EOF",
		text,
		kinds,
		expected,
		loc = loc,
	)
}

expect_diagnostics :: proc(
	t: ^testing.T,
	text: string,
	diagnostics: []diag.Diagnostic,
	expected: []Expected_Diagnostic,
	loc := #caller_location,
) {
	got := make([]Expected_Diagnostic, len(diagnostics), context.temp_allocator)
	for d, i in diagnostics {
		got[i] = {d.code, d.span.start, d.span.end, d.args[0]}
	}
	testing.expectf(
		t,
		slice.equal(got, expected),
		"%q: diagnostics %v, want %v",
		text,
		got,
		expected,
		loc = loc,
	)
}

// tokenize tokenizes text as file 0 into the temp allocator, which the test runner frees before
// each test, and sorts the diagnostics into print order.
tokenize :: proc(text: string) -> ([]parse.Token, []diag.Diagnostic) {
	tokens, diagnostics := parse.tokenize(text, 0, context.temp_allocator)
	diag.sort(diagnostics)
	return tokens, diagnostics
}
