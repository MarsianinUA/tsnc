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
		// The two fixes core:strconv's round_shortest lacks: the round up that carries through 9s
		// (it answered ...560 for the first), and the decimal points of the bounds aligned.
		{426147580146789570, "426147580146789570"},
		{28206292283999998000, "28206292283999998000"},
		{1.3649515199999999e21, "1.3649515199999999e+21"},
	}
	for c in cases {
		got := text(c.value)
		testing.expectf(t, got == c.text, "to_string: got %q, want %q", got, c.text)
	}
}

// String(x) of every double splitmix64 draws from seed 0, hashed with FNV-1a over the texts, each
// followed by a newline. The second draw keeps the exponent within [2^58, 2^71), where the old
// round_shortest of core:strconv differed from Node about once in five hundred. Node gives:
//
//	node -e 'const M = (1n << 64n) - 1n; let s = 0n; const next = () => { s = (s + 0x9e3779b97f4a7c15n) & M; let z = s; z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & M; z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & M; return z ^ (z >> 31n) }; const b = new BigUint64Array(1), f = new Float64Array(b.buffer); const run = (n, bits) => { s = 0n; let h = 0x811c9dc5; for (let i = 0; i < n; i++) { b[0] = bits(next()); const t = String(f[0]) + "\n"; for (let j = 0; j < t.length; j++) h = Math.imul(h ^ t.charCodeAt(j), 16777619) >>> 0 } return h.toString(16) }; console.log(run(100000, r => r), run(200000, r => (1081n + (r >> 52n) % 13n) << 52n | r & ((1n << 52n) - 1n)))'
//
// A million random doubles matched as well, which takes too long for a unit test.
@(test)
to_string_matches_node_over_random_doubles :: proc(t: ^testing.T) {
	buf: [num.STRING_MAX]byte
	state: u64
	h := u32(0x811c9dc5)
	for _ in 0 ..< 100_000 {
		hash_text(&h, num.to_string(buf[:], transmute(f64)splitmix(&state)))
	}
	testing.expect_value(t, h, 0xe1c55e46)

	state = 0
	h = 0x811c9dc5
	for _ in 0 ..< 200_000 {
		r := splitmix(&state)
		bits := (1081 + (r >> 52) % 13) << 52 | r & (1 << 52 - 1)
		hash_text(&h, num.to_string(buf[:], transmute(f64)bits))
	}
	testing.expect_value(t, h, 0xe48b7a26)
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

// parseFloat of literals longer than the 384 digits decimal.Decimal holds, among them the halfway
// points between two doubles written out in full, where one more digit decides. For example:
//
//	node -e 'const five = (5n ** 1075n).toString(); console.log(parseFloat("0." + "0".repeat(1075 - five.length) + five))'
@(test)
parse_float_reads_literals_of_any_length :: proc(t: ^testing.T) {
	zeros :: proc(count: int) -> string {
		return strings.repeat("0", count, context.temp_allocator)
	}
	join :: proc(parts: ..string) -> string {
		return strings.concatenate(parts, context.temp_allocator)
	}

	// 2^-1075, halfway between zero and the smallest denormal, is 5^1075 after the point.
	five := digits_of(1, 5, 1075)
	tiny := join("0.", zeros(1075 - len(five)), five)
	// 2^1024 - 2^970, halfway between the largest double and the power of two past it. It is even
	// and does not end in 0, so one less is its last digit less one.
	top := digits_of(1 << 54 - 1, 2, 970)
	below := transmute([]byte)strings.clone(top, context.temp_allocator)
	below[len(below) - 1] -= 1
	// 1 + 2^-53, halfway between 1 and the next double.
	half := "1.00000000000000011102230246251565404236316680908203125"

	cases := [?]struct {
		text:  string,
		value: f64,
	} {
		{tiny, 0}, // a tie goes to the even mantissa, and zero is even
		{join(tiny, "1"), 5e-324},
		{top, INF},
		{string(below), 1.7976931348623157e308},
		{join(half, zeros(400)), 1},
		{join(half, zeros(400), "1"), 1.0000000000000002},
		// decimal.set counts the point from the 384 digits it keeps and read this as 1e-17.
		{join("1", zeros(400), "e-400"), 1},
		// decimal.set stops an exponent from growing at 1e4.
		{join("0.", zeros(100000), "1e100005"), 10000},
		{"1e999999999999999999999", INF},
		{"1e-999999999999999999", 0},
	}
	for c in cases {
		got, want := num.parse_float(c.text), c.value
		testing.expectf(
			t,
			same(got, want),
			"parse_float of %d characters: got %v, want %v",
			len(c.text),
			got,
			want,
		)
	}
}

// Math.round(x)
// Number(text). Where the rounding is the point, the value is the bit pattern
// Buffer.writeDoubleLE gives, for example:
//
//	node -e 'const b = Buffer.alloc(8); b.writeDoubleLE(Number("0x20000000000003")); console.log(b.readBigUInt64LE().toString(16))'
@(test)
to_number_matches_node :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		value: f64,
	} {
		{"", 0},
		{" 12 ", 12},
		{"+12", 12},
		{"-0", NEGATIVE_ZERO},
		{"1e3", 1000},
		{".5", 0.5},
		{"5.", 5},
		{"12e-1 ", 1.2},
		{"Infinity", INF},
		{"-Infinity", -INF},
		// The whole text must be the literal, less the whitespace around it.
		{"12px", NAN},
		{"1_0", NAN},
		{".", NAN},
		{"1e", NAN},
		{"infinity", NAN},
		{"\xc2\xa0 7\xe2\x80\xa8", 7},
		{"\xc2\x853", NAN},
		// Integers in radix 16, 8 and 2, which take no sign.
		{"0x10", 16},
		{"0X1f", 31},
		{"0o17", 15},
		{"0b101", 5},
		{"0x", NAN},
		{"-0x1", NAN},
		{"0x1g", NAN},
		{"0b102", NAN},
		// Past 53 bits: a tie goes to the even neighbor, anything above it up.
		{"0x1fffffffffffff", 0h433f_ffff_ffff_ffff},
		{"0x20000000000001", 0h4340_0000_0000_0000},
		{"0x20000000000003", 0h4340_0000_0000_0002},
		{"0x200000000000011", 0h4380_0000_0000_0001},
		{"0b111111111111111111111111111111111111111111111111111111111111", 0h43b0_0000_0000_0000},
	}
	for c in cases {
		got, want := num.to_number(c.text), c.value
		testing.expectf(t, same(got, want), "to_number(%q): got %v, want %v", c.text, got, want)
	}
	// Past the largest double.
	digits := strings.repeat("f", 300, context.temp_allocator)
	wide := strings.concatenate({"0x", digits}, context.temp_allocator)
	testing.expectf(t, same(num.to_number(wide), INF), "to_number of 300 hex digits")
}

// parseInt(text), with the bit patterns taken as for to_number.
@(test)
parse_int_matches_node :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		value: f64,
	} {
		{"0x1f", 31},
		{"12.9", 12},
		{"-0.5", NEGATIVE_ZERO},
		{"-0", NEGATIVE_ZERO},
		{"  -12abc", -12},
		{"+7", 7},
		{"1e+21", 1},
		{"", NAN},
		{"abc", NAN},
		{"0x", NAN},
		{"0xg", NAN},
		{"  0x10z", 16},
		{"-0x10", -16},
		{"9007199254740993", 0h4340_0000_0000_0000},
		{"10000000000000000000000000000001", 0h465f_8def_8808_b024},
		{"123456789012345678901234567890", 0h45f8_ee90_ff6c_373e},
		{"0x20000000000003", 0h4340_0000_0000_0002},
		{"0x200000000000011", 0h4380_0000_0000_0001},
	}
	for c in cases {
		got, want := num.parse_int(c.text), c.value
		testing.expectf(t, same(got, want), "parse_int(%q): got %v, want %v", c.text, got, want)
	}
	// Leading zeros are not significant digits, and 310 of those are past the largest double.
	zeros := strings.repeat("0", 400, context.temp_allocator)
	one := strings.concatenate({zeros, "1"}, context.temp_allocator)
	testing.expectf(t, same(num.parse_int(one), 1), "parse_int of 400 zeros and a one")
	nines := strings.repeat("9", 320, context.temp_allocator)
	testing.expectf(t, same(num.parse_int(nines), INF), "parse_int of 320 nines")
}

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

// process.exit(code) as Node 24 takes it: an integer reduced by ToInt32, and a RangeError, which is
// `ok = false`, for anything else.
@(test)
exit_code_is_to_int32_of_an_integer :: proc(t: ^testing.T) {
	Case :: struct {
		code: f64,
		exit: int,
		ok:   bool,
	}
	cases := [?]Case {
		{0, 0, true},
		{1, 1, true},
		{255, 255, true},
		{256, 256, true},
		{-1, -1, true},
		{4294967296 + 73, 73, true},
		{4294967299, 3, true},
		{-2147483649, 2147483647, true},
		{2147483648, -2147483648, true},
		{9007199254740992, 0, true},
		{NAN, 0, false},
		{INF, 0, false},
		{-INF, 0, false},
		{1.9, 0, false},
		{99.5, 0, false},
	}
	for c in cases {
		exit, ok := num.exit_code(c.code)
		testing.expectf(
			t,
			exit == c.exit && ok == c.ok,
			"exit_code(%v) = %v, %v; want %v, %v",
			c.code,
			exit,
			ok,
			c.exit,
			c.ok,
		)
	}
}

// ToIntegerOrInfinity, then the start `slice` reads out of it:
//
//	node -e 'for (const s of [2.9, -2.9, -1, -10, 10, NaN, Infinity, -Infinity, -0]) console.log(s, "abcde".slice(s).length)'
@(test)
positions_become_integers_before_they_become_indices :: proc(t: ^testing.T) {
	testing.expect(t, same(num.to_integer(NAN), 0))
	testing.expect(t, same(num.to_integer(2.9), 2))
	testing.expect(t, same(num.to_integer(-2.9), -2))
	testing.expect(t, same(num.to_integer(INF), INF))
	testing.expect(t, same(num.to_integer(-INF), -INF))

	// The start each case gives "abcde".slice is 5 minus the length Node prints.
	cases := [?]struct {
		value: f64,
		index: int,
	} {
		{2.9, 2},
		{-2.9, 3},
		{-1, 4},
		{-10, 0},
		{10, 5},
		{NAN, 0},
		{INF, 5},
		{-INF, 0},
		{NEGATIVE_ZERO, 0},
	}
	for c in cases {
		got := num.relative_index(c.value, 5)
		testing.expectf(
			t,
			got == c.index,
			"relative_index(%v, 5) = %d, want %d",
			c.value,
			got,
			c.index,
		)
	}
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

splitmix :: proc(state: ^u64) -> u64 {
	state^ += 0x9e3779b97f4a7c15
	z := state^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// hash_text adds the bytes of text and a newline to an FNV-1a hash.
hash_text :: proc(h: ^u32, text: string) {
	for i in 0 ..< len(text) {
		h^ = (h^ ~ u32(text[i])) * 16777619
	}
	h^ = (h^ ~ '\n') * 16777619
}

// digits_of answers the decimal digits of start * factor^times.
digits_of :: proc(start: u64, factor, times: int) -> string {
	digits := make([dynamic]byte, context.temp_allocator) // least significant first
	for n := start; n > 0; n /= 10 {
		append(&digits, byte(n % 10))
	}
	for _ in 0 ..< times {
		carry := 0
		for &digit in digits {
			product := int(digit) * factor + carry
			digit, carry = byte(product % 10), product / 10
		}
		for ; carry > 0; carry /= 10 {
			append(&digits, byte(carry % 10))
		}
	}
	text := make([]byte, len(digits), context.temp_allocator)
	for digit, i in digits {
		text[len(digits) - 1 - i] = '0' + digit
	}
	return string(text)
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
