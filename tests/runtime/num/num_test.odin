package num_tests

import "core:strings"
import "core:testing"

import "../../../src/runtime/num"

// Every expected value below came out of Node 24, which is the only authority on these rules; the
// header of each test names the expression that produced it. Regenerate a row with, for example:
//
//	node -e 'console.log(JSON.stringify(String(1e21)))'
//
// NaN, the infinities and the negative zero are spelled as bit patterns, so that no case depends on
// the arithmetic it is meant to check.
NAN :: 0h7ff8_0000_0000_0000
INF :: 0h7ff0_0000_0000_0000
NEGATIVE_ZERO :: 0h8000_0000_0000_0000

// String(value)
@(test)
to_string_matches_node :: proc(t: ^testing.T) {
	cases := [?]struct {
		value: f64,
		text:  string,
	} {
		{0, "0"},
		{NEGATIVE_ZERO, "0"},
		{NAN, "NaN"},
		{INF, "Infinity"},
		{-INF, "-Infinity"},
		{1, "1"},
		{-1.5, "-1.5"},
		{100, "100"},
		{123.456, "123.456"},
		{4.35, "4.35"},
		{1.0 / 3.0, "0.3333333333333333"},
		{0.30000000000000004, "0.30000000000000004"},
		// The thresholds of requirements 3.1: decimal form while 1e-7 <= |value| < 1e21.
		{1e20, "100000000000000000000"},
		{1e21, "1e+21"},
		{9.999999999999999e20, "999999999999999900000"},
		{1.2345678901234568e21, "1.2345678901234568e+21"},
		{1e-6, "0.000001"},
		{1e-7, "1e-7"},
		{1.2e-5, "0.000012"},
		// The extremes of a double, where the exponent needs all three of its digits.
		{5e-324, "5e-324"},
		{1e-323, "1e-323"},
		{1e300, "1e+300"},
		{1.7976931348623157e308, "1.7976931348623157e+308"},
		// Two to the fifty-third, where the integers stop being exact.
		{9007199254740992, "9007199254740992"},
		{9007199254740994, "9007199254740994"},
	}
	for c in cases {
		got := text(c.value)
		testing.expectf(t, got == c.text, "to_string: got %q, want %q", got, c.text)
	}
}

// Odin folds an untyped constant expression exactly and rounds it once, so a tenth plus a fifth
// written in the table above would be the double nearest three tenths. The sum every article about
// floating point opens with needs two doubles first.
@(test)
a_tenth_plus_a_fifth_is_not_three_tenths :: proc(t: ^testing.T) {
	tenth, fifth := f64(0.1), f64(0.2)
	testing.expect_value(t, text(tenth + fifth), "0.30000000000000004")
}

// STRING_MAX is a promise to every caller, and console makes its buffer that size. Rather than
// trust the arithmetic behind it, sweep the whole exponent range with the mantissas that produce
// the most digits, all of them negative so that the sign counts too.
@(test)
to_string_never_outgrows_the_buffer_it_promises :: proc(t: ^testing.T) {
	longest, widest := 0, f64(0)
	for exponent in u64(0) ..< 2047 {
		for mantissa in ([?]u64{0, 1, 0x5555_5555_5555, 0xf_ffff_ffff_ffff}) {
			value := transmute(f64)(u64(1) << 63 | exponent << 52 | mantissa)
			buf: [num.STRING_MAX]byte
			if got := len(num.to_string(buf[:], value)); got > longest {
				longest, widest = got, value
			}
		}
	}
	testing.expectf(
		t,
		longest <= num.STRING_MAX,
		"%v took %d bytes, STRING_MAX is %d",
		widest,
		longest,
		num.STRING_MAX,
	)
	// The widest form, spelled out: a sign, "0.", five zeros and the seventeen digits a double can
	// need. Pinned so that a change to the layout has to face the buffer size again.
	testing.expect_value(t, longest, 25)
}

// value.toFixed(digits)
@(test)
to_fixed_matches_node :: proc(t: ^testing.T) {
	cases := [?]struct {
		value:  f64,
		digits: f64,
		text:   string,
	} {
		{0, 2, "0.00"},
		{NEGATIVE_ZERO, 2, "0.00"},
		{-0.0001, 2, "-0.00"},
		{NAN, 2, "NaN"},
		{INF, 2, "Infinity"},
		{-INF, 2, "-Infinity"},
		{1.5, 0, "2"},
		{123.456, 0, "123"},
		{1234.5678, 3, "1234.568"},
		{0.5, 1, "0.5"},
		{0.6, 0, "1"},
		{0.06, 0, "0"},
		{0.000001, 0, "0"},
		{99.99, 1, "100.0"},
		// A tie goes to the larger number, which is a half away from zero. The half to even that
		// core:strconv rounds by would answer "1.2", "2" and "1" here.
		{0.5, 0, "1"},
		{1.5, 0, "2"},
		{2.5, 0, "3"},
		{-1.5, 0, "-2"},
		{1.25, 1, "1.3"},
		// These four only look like ties. The double is a little under or over, and the exact
		// expansion is what decides.
		{1.005, 2, "1.00"},
		{1.45, 1, "1.4"},
		{1.55, 1, "1.6"},
		{9.995, 2, "9.99"},
		{8.125, 2, "8.13"},
		{8.575, 2, "8.57"},
		// The integer part runs past the digits the double carries, and zeros fill the rest.
		{1e15, 2, "1000000000000000.00"},
		// Twenty digits of a double that carries seventeen: the rest is the exact expansion.
		{1.45, 20, "1.44999999999999995559"},
		// At and above 1e21 the text is the one Number::toString gives.
		{1e21, 2, "1e+21"},
		{-1e21, 0, "-1e+21"},
		// The digit count is coerced the way ECMAScript coerces it: NaN counts as zero, and a
		// fraction drops toward zero.
		{1.5, NAN, "2"},
		{1.5, -0.5, "2"},
		{1.5, 3.9, "1.500"},
	}
	for c in cases {
		got, ok := fixed(c.value, c.digits)
		testing.expectf(t, ok, "to_fixed(%v, %v): out of range", c.value, c.digits)
		testing.expectf(t, got == c.text, "to_fixed: got %q, want %q", got, c.text)
	}
}

// A digit count outside zero to a hundred is a RangeError in ECMAScript. v1 cannot throw, so it
// comes back as a refusal the caller turns into a runtime failure.
@(test)
to_fixed_refuses_a_digit_count_out_of_range :: proc(t: ^testing.T) {
	for digits in ([?]f64{-1, -2.5, 101, 100.001 * 1000, INF, -INF}) {
		_, ok := fixed(1.5, digits)
		testing.expectf(t, !ok, "to_fixed(1.5, %v): expected a refusal", digits)
	}
	// The range is read before the value is, so even NaN and an infinity are refused there.
	for value in ([?]f64{NAN, INF, 1e21}) {
		_, ok := fixed(value, 101)
		testing.expectf(t, !ok, "to_fixed(%v, 101): expected a refusal", value)
	}
	for digits in ([?]f64{0, 100, 100.9, -0.5, NAN}) {
		_, ok := fixed(1.5, digits)
		testing.expectf(t, ok, "to_fixed(1.5, %v): expected an answer", digits)
	}
}

// FIXED_MAX is the larger of the two promises and the harder one to reason about, since rounding
// can carry a digit into the integer part. Sweep the widest values against the widest digit counts.
@(test)
to_fixed_never_outgrows_the_buffer_it_promises :: proc(t: ^testing.T) {
	values := [?]f64 {
		-999999999999999900000, // twenty-one integer digits, the most that fits below 1e21
		-99999999999999999999.0, // the carry case, one below the same
		-0.9999999999999999,
		-5e-324,
		NEGATIVE_ZERO,
		-1234.5678,
	}
	longest := 0
	for value in values {
		for fraction in 0 ..= 100 {
			buf: [num.FIXED_MAX]byte
			got, ok := num.to_fixed(buf[:], value, f64(fraction))
			testing.expectf(t, ok, "to_fixed(%v, %d) was refused", value, fraction)
			if len(got) > longest {
				longest = len(got)
			}
		}
	}
	testing.expectf(
		t,
		longest <= num.FIXED_MAX,
		"the longest text took %d bytes, FIXED_MAX is %d",
		longest,
		num.FIXED_MAX,
	)
	// A sign, twenty-one integer digits, the point and a hundred fraction digits.
	testing.expect_value(t, longest, 123)
}

// parseFloat(text)
@(test)
parse_float_matches_node :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		value: f64,
	} {
		{"0.1", 0.1},
		{"000123", 123},
		{"-0", NEGATIVE_ZERO},
		{"3.14abc", 3.14},
		{"  42 ", 42},
		{"12.5e2e3", 1250},
		{"  -.5e-2xyz", -0.005},
		// A point needs a digit on one side of it, and an exponent needs one after it. The prefix
		// that reads is the longest one the grammar accepts, so "1e" is 1.
		{".5", 0.5},
		{"5.", 5},
		{"-5.", -5},
		{"1e3", 1000},
		{"1e", 1},
		{"1e+", 1},
		{".", NAN},
		{"+.e3", NAN},
		{"", NAN},
		{"abc", NAN},
		// Infinity is a word of the grammar, spelled exactly.
		{"Infinity", INF},
		{"+Infinity", INF},
		{"-Infinity", -INF},
		{"Infinityx", INF},
		{"infinity", NAN},
		{"In", NAN},
		// What core:strconv would take and ECMAScript does not: a hexadecimal literal and the
		// underscores between digits.
		{"0x10", 0},
		{"1_000", 1},
		// A unit in the last place. strconv.parse_f64 answers 3.1415926499999998e+41 for the first
		// of these, because its fast path scales the mantissa and then tests the value it held
		// before scaling. Odin folds the constants on the right exactly, so they are Node's values.
		{"3.14159265e41", 3.14159265e41},
		{"6.02214076e44", 6.02214076e44},
		{"1278572e37", 1278572e37},
		{"1800601e36", 1800601e36},
		// An overflow is an infinity and an underflow is zero, neither a failure to read.
		{"1e400", INF},
		{"-1e400", -INF},
		{"1e-400", 0},
		{"-1e-400", NEGATIVE_ZERO},
		// The denormals, and the value that has famously broken a parser or two.
		{"5e-324", 5e-324},
		{"1e-323", 1e-323},
		{"2.2250738585072011e-308", 2.2250738585072011e-308},
		{"11111111111111111111e-19", 1.1111111111111112},
		// Whitespace of the grammar: a no-break space and a line separator are skipped, while
		// U+0085 is not whitespace here although Unicode gives it the property.
		{"\xc2\xa03", 3},
		{"\xe2\x80\xa83", 3},
		{"\xef\xbb\xbf3", 3},
		{"\xc2\x853", NAN},
	}
	for c in cases {
		got, want := num.parse_float(c.text), c.value
		testing.expectf(t, same(got, want), "parse_float(%q): got %v, want %v", c.text, got, want)
	}
}

// Math.round(x)
@(test)
round_takes_a_half_toward_positive_infinity :: proc(t: ^testing.T) {
	cases := [?]struct {
		value, want: f64,
	} {
		{2.5, 3},
		{-2.5, -2},
		{1.4, 1},
		{-1.5, -1},
		{0.5, 1},
		// Everything from a half below zero up to it keeps the sign, which math.round would lose.
		{-0.5, NEGATIVE_ZERO},
		{-0.4, NEGATIVE_ZERO},
		{NEGATIVE_ZERO, NEGATIVE_ZERO},
		// The largest double below a half. Rounding x + 0.5 would answer one here.
		{0.49999999999999994, 0},
		// At two to the fifty-second every double is already an integer.
		{4503599627370496, 4503599627370496},
		{NAN, NAN},
		{INF, INF},
		{-INF, -INF},
	}
	for c in cases {
		got := num.round(c.value)
		testing.expectf(t, same(got, c.want), "round(%v): got %v, want %v", c.value, got, c.want)
	}
}

// Math.max(a, b) and Math.min(a, b). The compiler folds a longer call into a chain of these, and
// an empty one into a constant, so two arguments is the whole of it.
@(test)
max_and_min_answer_nan_and_order_the_two_zeros :: proc(t: ^testing.T) {
	testing.expect(t, same(num.max(NAN, 1), NAN))
	testing.expect(t, same(num.max(1, NAN), NAN))
	testing.expect(t, same(num.min(NAN, 1), NAN))
	testing.expect(t, same(num.min(1, NAN), NAN))

	testing.expect(t, same(num.max(NEGATIVE_ZERO, 0), 0))
	testing.expect(t, same(num.max(0, NEGATIVE_ZERO), 0))
	testing.expect(t, same(num.min(NEGATIVE_ZERO, 0), NEGATIVE_ZERO))
	testing.expect(t, same(num.min(0, NEGATIVE_ZERO), NEGATIVE_ZERO))

	testing.expect(t, same(num.max(2, 3), 3))
	testing.expect(t, same(num.min(2, 3), 2))
	testing.expect(t, same(num.max(-INF, INF), INF))
	testing.expect(t, same(num.min(-INF, INF), -INF))
}

// process.exit(code): an integer the OS keeps the low bits of, and zero for anything that is not a
// finite number.
@(test)
exit_code_keeps_the_low_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, num.exit_code(0), 0)
	testing.expect_value(t, num.exit_code(1), 1)
	testing.expect_value(t, num.exit_code(255), 255)
	testing.expect_value(t, num.exit_code(3.9), 3)
	testing.expect_value(t, num.exit_code(-1), -1)
	testing.expect_value(t, num.exit_code(NAN), 0)
	testing.expect_value(t, num.exit_code(INF), 0)
	testing.expect_value(t, num.exit_code(-INF), 0)
	testing.expect_value(t, num.exit_code(1e30), 0)
}

// Both conversions write into the caller's buffer, and a test wants the text to outlive the call.
text :: proc(value: f64) -> string {
	buf: [num.STRING_MAX]byte
	return strings.clone(num.to_string(buf[:], value), context.temp_allocator)
}

fixed :: proc(value, digits: f64) -> (string, bool) {
	buf: [num.FIXED_MAX]byte
	got, ok := num.to_fixed(buf[:], value, digits)
	return strings.clone(got, context.temp_allocator), ok
}

// same is equality for these tables: NaN matches NaN, and the two zeros do not match each other.
same :: proc(a, b: f64) -> bool {
	if a != a || b != b {
		return a != a && b != b
	}
	if a != b {
		return false
	}
	return (transmute(u64)a) >> 63 == (transmute(u64)b) >> 63
}
