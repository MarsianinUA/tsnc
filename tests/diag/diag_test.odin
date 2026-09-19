package diag_tests

import "core:strconv"
import "core:strings"
import "core:testing"

import "../../src/diag"
import "../../src/source"

@(test)
every_code_has_a_text_and_a_hint :: proc(t: ^testing.T) {
	for code in diag.Code {
		_, text, hint := render_code(code)
		testing.expectf(t, text != "", "%v has no text", code)
		testing.expectf(t, hint != "", "%v has no hint", code)
	}
}

@(test)
every_construct_has_a_text :: proc(t: ^testing.T) {
	for construct in diag.Construct {
		text := diag.construct_text(construct)
		testing.expectf(t, text != "", "%v has no text", construct)
	}
}

@(test)
every_code_has_its_own_four_digit_number :: proc(t: ^testing.T) {
	numbers: [diag.Code]string
	for code in diag.Code {
		numbers[code], _, _ = render_code(code)
		value, is_number := strconv.parse_int(numbers[code], 10)
		is_four_digits := is_number && 1000 <= value && value <= 9999
		testing.expectf(t, is_four_digits, "%v has the number %q", code, numbers[code])
	}
	for number, code in numbers {
		for other, other_code in numbers {
			if other_code > code {
				testing.expectf(
					t,
					number != other,
					"%v and %v share T%s",
					code,
					other_code,
					number,
				)
			}
		}
	}
}

@(test)
render_fills_the_arguments_in_the_text_and_the_hint :: proc(t: ^testing.T) {
	file := source.make_file("src/main.ts", "f(1 }")
	defer delete(file.line_starts)

	d := diag.Diagnostic {
		code = .Expected_Token,
		span = {start = 4, end = 5},
		args = {"`)`", "`}`"},
	}
	testing.expect_value(
		t,
		render({file}, d),
		"src/main.ts:1:5: error[T1007]: expected `)`, found `}`\n" +
		"  hint: add `)` here, or look before this point for an unclosed bracket or a missing operator\n",
	)
}

@(test)
render_locates_the_span_in_its_own_file :: proc(t: ^testing.T) {
	first := source.make_file("a.ts", "let x = 1\n")
	defer delete(first.line_starts)
	// The error is on line 2 after three Cyrillic letters, two bytes and one UTF-16 unit each.
	second := source.make_file("b.ts", "x\nпри = @")
	defer delete(second.line_starts)

	d := diag.Diagnostic {
		code = .Unexpected_Character,
		span = {file = 1, start = 11, end = 12},
		args = {0 = "@"},
	}
	output := render({first, second}, d)
	testing.expectf(t, strings.has_prefix(output, "b.ts:2:7: error[T1001]: "), "got %q", output)
}

@(test)
sort_orders_by_file_then_offset_then_code :: proc(t: ^testing.T) {
	diagnostics := [?]diag.Diagnostic {
		{code = .Var_Declaration, span = {file = 1, start = 0}},
		{code = .Var_Declaration, span = {file = 0, start = 5}},
		{code = .Eval, span = {file = 0, start = 9}},
		{code = .Unexpected_Character, span = {file = 0, start = 5}},
	}
	diag.sort(diagnostics[:])

	expected := [?]diag.Diagnostic {
		{code = .Unexpected_Character, span = {file = 0, start = 5}},
		{code = .Var_Declaration, span = {file = 0, start = 5}},
		{code = .Eval, span = {file = 0, start = 9}},
		{code = .Var_Declaration, span = {file = 1, start = 0}},
	}
	testing.expect_value(t, diagnostics, expected)
}

@(test)
sort_keeps_the_input_order_of_equal_keys :: proc(t: ^testing.T) {
	// Four keys, eight diagnostics each. The key ignores span.end, so end records the input order.
	diagnostics: [32]diag.Diagnostic
	for &d, i in diagnostics {
		d = {
			code = .Eval,
			span = {start = i32(i % 4), end = i32(i)},
		}
	}
	diag.sort(diagnostics[:])

	for i in 1 ..< len(diagnostics) {
		before, after := diagnostics[i - 1].span, diagnostics[i].span
		same_key := before.start == after.start
		in_order := before.start < after.start || same_key && before.end < after.end
		testing.expectf(t, in_order, "%v comes before %v", before, after)
	}
}

// render_code renders code at the start of an empty file and splits the output into its parts.
render_code :: proc(code: diag.Code) -> (number, text, hint: string) {
	file := source.make_file("a.ts", "")
	defer delete(file.line_starts)

	output := render({file}, {code = code, args = {"x", "y"}})
	error_line, _, hint_line := strings.partition(output, "\n")
	after_code := strings.trim_prefix(error_line, "a.ts:1:1: error[T")
	number, _, text = strings.partition(after_code, "]: ")
	hint = strings.trim_suffix(strings.trim_prefix(hint_line, "  hint: "), "\n")
	return
}

render :: proc(files: []source.File, d: diag.Diagnostic) -> string {
	b := strings.builder_make(context.temp_allocator)
	err := diag.render(strings.to_writer(&b), files, d)
	assert(err == nil)
	return strings.to_string(b)
}
