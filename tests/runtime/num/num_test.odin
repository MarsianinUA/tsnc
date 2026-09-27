package num_tests

import "core:strings"
import "core:testing"

import "../../../src/runtime/num"

// What the conversions answer for a value is pinned by the programs of tests/diff; the tests here
// sweep more values than a program holds, or check a promise no program can see. Node 24 is the
// authority on the rules, and a test names the expression that produced its expectation.
//
// NaN, the infinities and the negative zero are spelled as bit patterns, so that no case depends on
// the arithmetic it is meant to check.
NAN :: 0h7ff8_0000_0000_0000
INF :: 0h7ff0_0000_0000_0000
NEGATIVE_ZERO :: 0h8000_0000_0000_0000

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

// fixed clones the text out of the buffer to_fixed writes, so that it outlives the call.
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
