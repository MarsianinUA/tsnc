package parse

/*
Tokens (tokenize); the package doc is in parse.odin.
- The array always ends with one EOF token. Spaces, line breaks and comments make no tokens; a line
  break before a token, also one inside a block comment, sets its line_break_before, which is what
  automatic semicolon insertion needs. A `#!` line at the very start is a comment.
- Line terminators are \n, \r, \r\n, U+2028 and U+2029, read by source.line_terminator_size, so a
  line here is the line of a diagnostic. Spaces are tab, \v, \f, space, U+00A0, U+FEFF and the
  Unicode space separators.
- A name starts with a letter, `$` or `_` and goes on with those and digits, combining marks,
  U+200C and U+200D: ID_Start and ID_Continue as close as core:unicode gets. `\u` escapes in names
  are not supported: the backslash is an unexpected character.
- `/` is always division. Regular expression literals are v2 (requirements 2.2), and telling them
  apart from division needs the parser.
- A template literal is one token per text part: No_Substitution_Template, or Template_Head, then
  Template_Middle after each inner `}`, then Template_Tail. tokenize counts the `{` inside every
  open `${` itself, so a `}` of an object literal inside a substitution does not end it.
- A number, a string or a template part carries its cooked value: escapes applied, and \r\n or \r
  in a template turned into \n. A string value is UTF-8 in which a lone surrogate escape keeps its
  three-byte WTF-8 form (see ast.String_Literal).

Errors: an unknown character is reported and skipped, so it makes no token. A string ends at the
end of its line, a template or a block comment at the end of the file. A malformed number is one
Number token, a name or a digit glued to its end included (`3in`, `10n`). Rules from strict mode
hold, since every file is a module: no legacy octal numbers (`017`, `08`) and no octal escapes.

Memory: the token array, the diagnostics and every cooked value that differs from its source text
are allocated with the allocator passed in. Names, the other cooked values and the diagnostic
arguments borrow the source text. Scratch data goes to context.temp_allocator.
*/

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import "../diag"
import "../source"

// tokenize splits text, the text of file, into tokens. It reports every problem it finds as a
// diagnostic, in the order it finds them, and always returns the whole token array.
tokenize :: proc(
	text: string,
	file: source.File_ID,
	allocator := context.allocator,
) -> (
	tokens: []Token,
	diagnostics: []diag.Diagnostic,
) {
	ensure(len(text) <= source.MAX_FILE_SIZE)

	t := Tokenizer {
		text            = text,
		file            = file,
		allocator       = allocator,
		tokens          = make([dynamic]Token, allocator),
		diagnostics     = make([dynamic]diag.Diagnostic, allocator),
		template_depths = make([dynamic]int, context.temp_allocator),
	}
	defer delete(t.template_depths)

	if strings.has_prefix(text, "#!") {
		skip_line_comment(&t)
	}
	for {
		skip_trivia(&t)
		if t.offset == len(text) {
			break
		}
		scan_token(&t)
	}
	add_token(&t, .EOF, t.offset)
	return t.tokens[:], t.diagnostics[:]
}

// Tokenizer is the state of one tokenize call.
@(private)
Tokenizer :: struct {
	text:              string,
	file:              source.File_ID,
	allocator:         runtime.Allocator, // for cooked values; tokens and diagnostics hold it too
	offset:            int, // the next byte to read
	line_break_before: bool, // for the next token
	// One entry per `${` still open: how many `{` are open inside it. A `}` that finds 0 closes the
	// substitution and continues the template.
	template_depths:   [dynamic]int,
	tokens:            [dynamic]Token,
	diagnostics:       [dynamic]diag.Diagnostic,
}

// Cooked builds the cooked value of a string or a template part. It borrows the source text until
// the value first differs from it, then copies into buffer.
@(private)
Cooked :: struct {
	start:     int, // where the value's source text starts
	run_start: int, // where the source text not yet copied into buffer starts
	buffer:    [dynamic]u8, // nil while the value is a slice of the source text
}

@(private)
Punctuator :: struct {
	text: string,
	kind: Token_Kind,
}

// PUNCTUATORS has every punctuator, longer ones first, so the first match is the longest.
@(private, rodata)
PUNCTUATORS := [?]Punctuator {
	{"...", .Dot_Dot_Dot},
	{"===", .Equal_Equal_Equal},
	{"!==", .Bang_Equal_Equal},
	{"**=", .Star_Star_Equal},
	{"<<=", .Less_Less_Equal},
	{"&&=", .Amp_Amp_Equal},
	{"||=", .Bar_Bar_Equal},
	{"??=", .Question_Question_Equal},
	{"=>", .Arrow},
	{"==", .Equal_Equal},
	{"!=", .Bang_Equal},
	{"**", .Star_Star},
	{"++", .Plus_Plus},
	{"--", .Minus_Minus},
	{"<<", .Less_Less},
	{"<=", .Less_Equal},
	{"&&", .Amp_Amp},
	{"||", .Bar_Bar},
	{"??", .Question_Question},
	{"?.", .Question_Dot},
	{"+=", .Plus_Equal},
	{"-=", .Minus_Equal},
	{"*=", .Star_Equal},
	{"/=", .Slash_Equal},
	{"%=", .Percent_Equal},
	{"&=", .Amp_Equal},
	{"|=", .Bar_Equal},
	{"^=", .Caret_Equal},
	{"{", .Open_Brace},
	{"}", .Close_Brace},
	{"(", .Open_Paren},
	{")", .Close_Paren},
	{"[", .Open_Bracket},
	{"]", .Close_Bracket},
	{".", .Dot},
	{";", .Semicolon},
	{",", .Comma},
	{":", .Colon},
	{"?", .Question},
	{"@", .At},
	{"+", .Plus},
	{"-", .Minus},
	{"*", .Star},
	{"/", .Slash},
	{"%", .Percent},
	{"<", .Less},
	{">", .Greater},
	{"=", .Equal},
	{"!", .Bang},
	{"~", .Tilde},
	{"&", .Amp},
	{"|", .Bar},
	{"^", .Caret},
}

// scan_token reads one token at t.offset, which is not trivia and not the end of the text.
@(private)
scan_token :: proc(t: ^Tokenizer) {
	start := t.offset
	rest := t.text[start:]
	r, r_size := utf8.decode_rune_in_string(rest)
	switch {
	case is_decimal_digit(rest[0]) || rest[0] == '.' && is_decimal_digit(byte_at(rest, 1)):
		scan_number(t)
		return
	case rest[0] == '"' || rest[0] == '\'':
		scan_string(t)
		return
	case rest[0] == '`':
		t.offset += 1
		scan_template_part(t, start)
		return
	case is_name_start(r):
		t.offset = name_end(t.text, start)
		name := t.text[start:t.offset]
		add_token(t, reserved_word_kind(name), start, name)
		return
	}

	kind, size, found := match_punctuator(rest)
	if !found {
		t.offset += r_size
		report(t, .Unexpected_Character, start, t.offset, t.text[start:t.offset])
		return
	}
	t.offset += size

	depth_count := len(t.template_depths)
	#partial switch kind {
	case .Open_Brace:
		if depth_count > 0 {
			t.template_depths[depth_count - 1] += 1
		}
	case .Close_Brace:
		closes_substitution := depth_count > 0 && t.template_depths[depth_count - 1] == 0
		if closes_substitution {
			pop(&t.template_depths)
			scan_template_part(t, start)
			return
		}
		if depth_count > 0 {
			t.template_depths[depth_count - 1] -= 1
		}
	}
	add_token(t, kind, start)
}

// match_punctuator finds the longest punctuator at the start of rest; size is its length.
@(private)
match_punctuator :: proc(rest: string) -> (kind: Token_Kind, size: int, found: bool) {
	for p in PUNCTUATORS {
		if !strings.has_prefix(rest, p.text) {
			continue
		}
		// `a?.5:b` is a conditional: `?` then the number `.5`.
		if p.kind == .Question_Dot && is_decimal_digit(byte_at(rest, 2)) {
			continue
		}
		return p.kind, len(p.text), true
	}
	return
}

// scan_number reads a number literal. Everything glued to it (a name, more digits) goes into the
// one token, so a malformed number is one diagnostic.
@(private)
scan_number :: proc(t: ^Tokenizer) {
	start := t.offset
	value: f64
	valid := true

	base := radix_prefix_base(t.text[start:])
	if base != 0 {
		t.offset += 2
		digits_start := t.offset
		count, digits_ok := scan_digits(t, base)
		valid = digits_ok && count > 0
		value = radix_value(t.text[digits_start:t.offset], base)
	} else {
		// `017` and `08` are legacy forms that strict mode rejects.
		next := byte_at(t.text, start + 1)
		has_leading_zero := t.text[start] == '0' && (is_decimal_digit(next) || next == '_')
		_, integer_ok := scan_digits(t, 10)
		valid = integer_ok && !has_leading_zero

		if byte_at(t.text, t.offset) == '.' {
			t.offset += 1
			_, fraction_ok := scan_digits(t, 10)
			valid = valid && fraction_ok
		}

		if c := byte_at(t.text, t.offset); c == 'e' || c == 'E' {
			t.offset += 1
			if sign := byte_at(t.text, t.offset); sign == '+' || sign == '-' {
				t.offset += 1
			}
			count, exponent_ok := scan_digits(t, 10)
			valid = valid && exponent_ok && count > 0
		}

		// parse_f64 skips the `_` separators and returns +Inf past the f64 range.
		value, _ = strconv.parse_f64(t.text[start:t.offset])
	}

	if end := name_end(t.text, t.offset); end > t.offset {
		valid = false
		t.offset = end
	}
	if !valid {
		report(t, .Invalid_Number, start, t.offset)
	}
	add_token(t, .Number, start, value)
}

// radix_prefix_base returns 16, 8 or 2 for text that starts with `0x`, `0o` or `0b` in either
// case, and 0 otherwise.
@(private)
radix_prefix_base :: proc(text: string) -> int {
	if len(text) < 2 || text[0] != '0' {
		return 0
	}
	switch text[1] {
	case 'x', 'X':
		return 16
	case 'o', 'O':
		return 8
	case 'b', 'B':
		return 2
	}
	return 0
}

// scan_digits reads digits of base and the `_` separators between them. ok is false when a `_`
// does not stand between two digits.
@(private)
scan_digits :: proc(t: ^Tokenizer, base: int) -> (count: int, ok: bool) {
	ok = true
	after_digit := false
	for t.offset < len(t.text) {
		c := t.text[t.offset]
		if c == '_' {
			before_digit := digit_value(byte_at(t.text, t.offset + 1)) < base
			ok = ok && after_digit && before_digit
			after_digit = false
		} else if digit_value(c) < base {
			count += 1
			after_digit = true
		} else {
			break
		}
		t.offset += 1
	}
	return
}

// radix_value is the value of the digits and `_` separators of a `0x`, `0o` or `0b` literal.
@(private)
radix_value :: proc(digits: string, base: int) -> f64 {
	exact: u64
	rounded: f64
	is_exact := true
	for c in transmute([]u8)digits {
		if c == '_' {
			continue
		}
		digit := u64(digit_value(c))
		if is_exact && exact > (max(u64) - digit) / u64(base) {
			// direct: past 2^64 every digit rounds, so the last bit may differ from JS; a big
			// integer conversion if a program ever needs such a literal.
			is_exact = false
			rounded = f64(exact)
		}
		if is_exact {
			exact = exact * u64(base) + digit
		} else {
			rounded = rounded * f64(base) + f64(digit)
		}
	}
	return f64(exact) if is_exact else rounded
}

// scan_string reads a string literal. It ends at the closing quote, or unterminated at the end of
// its line or of the text.
@(private)
scan_string :: proc(t: ^Tokenizer) {
	start := t.offset
	quote := t.text[start]
	t.offset += 1
	cooked := Cooked {
		start     = t.offset,
		run_start = t.offset,
	}

	terminated := false
	for t.offset < len(t.text) {
		c := t.text[t.offset]
		if c == quote {
			terminated = true
			break
		}
		if c == '\n' || c == '\r' {
			break
		}
		if c == '\\' {
			scan_escape(t, &cooked)
			continue
		}
		t.offset += 1
	}

	value := cooked_value(t, &cooked)
	if terminated {
		t.offset += 1
	} else {
		report(t, .Unterminated_String, start, t.offset)
	}
	add_token(t, .String, start, value)
}

// scan_template_part reads the text of a template up to a backtick or a `${`. start is the opening
// backtick or the `}` that closed the substitution before this part; t.offset is just past it.
@(private)
scan_template_part :: proc(t: ^Tokenizer, start: int) {
	opens_template := t.text[start] == '`'
	// The kind of this part when a backtick ends it, and when a `${` does.
	last_kind: Token_Kind = .No_Substitution_Template if opens_template else .Template_Tail
	open_kind: Token_Kind = .Template_Head if opens_template else .Template_Middle
	cooked := Cooked {
		start     = t.offset,
		run_start = t.offset,
	}

	for t.offset < len(t.text) {
		switch t.text[t.offset] {
		case '`':
			value := cooked_value(t, &cooked)
			t.offset += 1
			add_token(t, last_kind, start, value)
			return
		case '$':
			if byte_at(t.text, t.offset + 1) != '{' {
				t.offset += 1
				continue
			}
			value := cooked_value(t, &cooked)
			t.offset += 2
			append(&t.template_depths, 0)
			add_token(t, open_kind, start, value)
			return
		case '\\':
			scan_escape(t, &cooked)
		case '\r':
			// \r\n and a lone \r both cook to \n.
			copy_run(t, &cooked)
			append(&cooked.buffer, '\n')
			t.offset += source.line_terminator_size(t.text, t.offset)
			cooked.run_start = t.offset
		case:
			t.offset += 1
		}
	}

	value := cooked_value(t, &cooked)
	report(t, .Unterminated_Template, start, t.offset)
	add_token(t, last_kind, start, value)
}

// scan_escape reads the escape sequence at t.offset, a backslash, and adds its value to cooked.
@(private)
scan_escape :: proc(t: ^Tokenizer, cooked: ^Cooked) {
	start := t.offset
	copy_run(t, cooked)
	t.offset += 1
	if t.offset == len(t.text) {
		// The caller reports the unterminated literal.
		cooked.run_start = t.offset
		return
	}

	valid := true
	c := t.text[t.offset]
	switch c {
	case 'b', 'f', 'n', 'r', 't', 'v':
		append(&cooked.buffer, control_character(c))
		t.offset += 1
	case '0' ..= '9':
		// Only `\0` not followed by a digit is allowed; the rest are octal escapes, which strict
		// mode rejects, or `\8` and `\9`.
		is_null := c == '0' && !is_decimal_digit(byte_at(t.text, t.offset + 1))
		if is_null {
			append(&cooked.buffer, 0)
			t.offset += 1
		} else {
			valid = false
			for is_decimal_digit(byte_at(t.text, t.offset)) {
				t.offset += 1
			}
		}
	case 'x':
		high := digit_value(byte_at(t.text, t.offset + 1))
		low := digit_value(byte_at(t.text, t.offset + 2))
		valid = high < 16 && low < 16
		if valid {
			append_code_point(&cooked.buffer, rune(high * 16 + low))
			t.offset += 3
		} else {
			t.offset += 2 if high < 16 else 1
		}
	case 'u':
		r, end, ok := read_unicode_escape(t.text, start)
		valid = ok
		if ok && 0xD800 <= r && r <= 0xDBFF {
			// `\uD83D\uDE00` is one code point, written as a surrogate pair.
			low, low_end, low_ok := read_unicode_escape(t.text, end)
			if low_ok && 0xDC00 <= low && low <= 0xDFFF {
				r = 0x10000 + ((r - 0xD800) << 10) + (low - 0xDC00)
				end = low_end
			}
		}
		if ok {
			append_code_point(&cooked.buffer, r)
		}
		t.offset = end
	case:
		if size := source.line_terminator_size(t.text, t.offset); size > 0 {
			// A line continuation adds nothing to the value.
			t.offset += size
		} else {
			// `\q` is `q`: the character after the backslash stays in the next run.
			cooked.run_start = t.offset
			_, char_size := utf8.decode_rune_in_string(t.text[t.offset:])
			t.offset += char_size
			return
		}
	}

	cooked.run_start = t.offset
	if !valid {
		report(t, .Invalid_Escape, start, t.offset, t.text[start:t.offset])
	}
}

// control_character is the character that `\b`, `\f`, `\n`, `\r`, `\t` or `\v` stands for.
@(private)
control_character :: proc(letter: byte) -> byte {
	switch letter {
	case 'b':
		return '\b'
	case 'f':
		return '\f'
	case 'n':
		return '\n'
	case 'r':
		return '\r'
	case 't':
		return '\t'
	case 'v':
		return '\v'
	}
	unreachable()
}

// read_unicode_escape reads `\uXXXX` or `\u{X...}` at text[start], the backslash. On failure end is
// past what it read, a closing `}` included, so the caller can report that text.
@(private)
read_unicode_escape :: proc(text: string, start: int) -> (r: rune, end: int, ok: bool) {
	if !strings.has_prefix(text[start:], "\\u") {
		return 0, start, false
	}

	i := start + 2
	if byte_at(text, i) == '{' {
		i += 1
		digit_count := 0
		value := 0
		for ; digit_value(byte_at(text, i)) < 16; i += 1 {
			// Capped so a long run of digits cannot overflow.
			value = min(value * 16 + digit_value(text[i]), 0x110000)
			digit_count += 1
		}
		if byte_at(text, i) != '}' {
			return 0, i, false
		}
		ok = digit_count > 0 && value <= utf8.MAX_RUNE
		return rune(value), i + 1, ok
	}

	value := 0
	for _ in 0 ..< 4 {
		digit := digit_value(byte_at(text, i))
		if digit >= 16 {
			return 0, i, false
		}
		value = value * 16 + digit
		i += 1
	}
	return rune(value), i, true
}

// append_code_point appends r in UTF-8. A lone surrogate keeps its three-byte WTF-8 form, which
// utf8.encode_rune would turn into U+FFFD.
@(private)
append_code_point :: proc(buffer: ^[dynamic]u8, r: rune) {
	if 0xD800 <= r && r <= 0xDFFF {
		append(buffer, 0xE0 | u8(r >> 12), 0x80 | u8(r >> 6) & 0x3F, 0x80 | u8(r) & 0x3F)
		return
	}
	bytes, size := utf8.encode_rune(r)
	append(buffer, ..bytes[:size])
}

// copy_run starts the buffer of cooked if needed and copies the source text from its run_start to
// t.offset into it.
@(private)
copy_run :: proc(t: ^Tokenizer, cooked: ^Cooked) {
	if cooked.buffer == nil {
		cooked.buffer = make([dynamic]u8, 0, t.offset - cooked.start + 16, t.allocator)
	}
	append(&cooked.buffer, t.text[cooked.run_start:t.offset])
}

// cooked_value ends the value of cooked at t.offset.
@(private)
cooked_value :: proc(t: ^Tokenizer, cooked: ^Cooked) -> string {
	if cooked.buffer == nil {
		return t.text[cooked.start:t.offset]
	}
	copy_run(t, cooked)
	return string(cooked.buffer[:])
}

// skip_trivia skips spaces, line breaks and comments, and notes a line break for the next token.
@(private)
skip_trivia :: proc(t: ^Tokenizer) {
	for t.offset < len(t.text) {
		rest := t.text[t.offset:]
		if size := source.line_terminator_size(t.text, t.offset); size > 0 {
			t.line_break_before = true
			t.offset += size
			continue
		}
		switch {
		case strings.has_prefix(rest, "//"):
			skip_line_comment(t)
			continue
		case strings.has_prefix(rest, "/*"):
			skip_block_comment(t)
			continue
		}

		r, size := utf8.decode_rune_in_string(rest)
		if !is_space(r) {
			return
		}
		t.offset += size
	}
}

// skip_line_comment skips to the line terminator that ends the comment and leaves it for
// skip_trivia.
@(private)
skip_line_comment :: proc(t: ^Tokenizer) {
	for t.offset < len(t.text) && source.line_terminator_size(t.text, t.offset) == 0 {
		t.offset += 1
	}
}

@(private)
skip_block_comment :: proc(t: ^Tokenizer) {
	start := t.offset
	t.offset += 2
	for t.offset < len(t.text) {
		if strings.has_prefix(t.text[t.offset:], "*/") {
			t.offset += 2
			return
		}
		if source.line_terminator_size(t.text, t.offset) > 0 {
			t.line_break_before = true
		}
		t.offset += 1
	}
	report(t, .Unterminated_Comment, start, t.offset)
}

// is_space reports the ECMAScript white space characters; line terminators are not among them.
@(private)
is_space :: proc(r: rune) -> bool {
	switch r {
	case '\t', '\v', '\f', ' ', 0xA0, 0xFEFF:
		return true
	case 0x1680, 0x2000 ..= 0x200A, 0x202F, 0x205F, 0x3000:
		// The Unicode space separators (Zs) above U+00FF.
		return true
	}
	return false
}

@(private)
is_name_start :: proc(r: rune) -> bool {
	switch r {
	case 'a' ..= 'z', 'A' ..= 'Z', '$', '_':
		return true
	}
	return r >= utf8.RUNE_SELF && unicode.is_letter(r)
}

@(private)
is_name_part :: proc(r: rune) -> bool {
	ZWNJ :: 0x200C
	ZWJ :: 0x200D
	switch r {
	case '0' ..= '9', ZWNJ, ZWJ:
		return true
	}
	if is_name_start(r) {
		return true
	}
	// unicode.is_digit also takes the superscripts in Latin-1, which are not ID_Continue.
	is_other_digit := r > unicode.MAX_LATIN1 && unicode.is_digit(r)
	return is_other_digit || unicode.is_nonspacing_mark(r) || unicode.is_spacing_mark(r)
}

// name_end is where the run of name characters that starts at text[start] ends.
@(private)
name_end :: proc(text: string, start: int) -> int {
	for r, i in text[start:] {
		if !is_name_part(r) {
			return start + i
		}
	}
	return len(text)
}

// reserved_word_kind is the kind of a name: its reserved word, or Identifier.
@(private)
reserved_word_kind :: proc(name: string) -> Token_Kind {
	switch name {
	case "await":
		return .Await
	case "break":
		return .Break
	case "case":
		return .Case
	case "catch":
		return .Catch
	case "class":
		return .Class
	case "const":
		return .Const
	case "continue":
		return .Continue
	case "debugger":
		return .Debugger
	case "default":
		return .Default
	case "delete":
		return .Delete
	case "do":
		return .Do
	case "else":
		return .Else
	case "enum":
		return .Enum
	case "export":
		return .Export
	case "extends":
		return .Extends
	case "false":
		return .False
	case "finally":
		return .Finally
	case "for":
		return .For
	case "function":
		return .Function
	case "if":
		return .If
	case "implements":
		return .Implements
	case "import":
		return .Import
	case "in":
		return .In
	case "instanceof":
		return .Instanceof
	case "interface":
		return .Interface
	case "let":
		return .Let
	case "new":
		return .New
	case "null":
		return .Null
	case "package":
		return .Package
	case "private":
		return .Private
	case "protected":
		return .Protected
	case "public":
		return .Public
	case "return":
		return .Return
	case "static":
		return .Static
	case "super":
		return .Super
	case "switch":
		return .Switch
	case "this":
		return .This
	case "throw":
		return .Throw
	case "true":
		return .True
	case "try":
		return .Try
	case "typeof":
		return .Typeof
	case "var":
		return .Var
	case "void":
		return .Void
	case "while":
		return .While
	case "with":
		return .With
	case "yield":
		return .Yield
	}
	return .Identifier
}

// digit_value is the value of a hexadecimal digit, or 16 for any other byte.
@(private)
digit_value :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return 16
}

@(private)
is_decimal_digit :: proc(c: byte) -> bool {
	return '0' <= c && c <= '9'
}

// byte_at is text[i], or 0 past the end.
@(private)
byte_at :: proc(text: string, i: int) -> byte {
	return text[i] if i < len(text) else 0
}

// add_token appends a token that spans text[start:t.offset].
@(private)
add_token :: proc(t: ^Tokenizer, kind: Token_Kind, start: int, value: Token_Value = nil) {
	token := Token {
		kind              = kind,
		line_break_before = t.line_break_before,
		span              = span_of(t, start, t.offset),
		value             = value,
	}
	append(&t.tokens, token)
	t.line_break_before = false
}

@(private)
report :: proc(t: ^Tokenizer, code: diag.Code, start, end: int, arg := "") {
	d := diag.Diagnostic {
		code = code,
		span = span_of(t, start, end),
		args = {0 = arg},
	}
	append(&t.diagnostics, d)
}

@(private)
span_of :: proc(t: ^Tokenizer, start, end: int) -> source.Span {
	return {file = t.file, start = i32(start), end = i32(end)}
}
