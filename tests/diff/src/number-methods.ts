// The Number methods of the subset (requirements 2.2): Number.isInteger, toString without a radix,
// toFixed and its corners, Number.parseFloat on the strings where parsing stops early or never
// starts, and String(n). Every value arrives through a parameter, so the unoptimized build computes
// it at run time.

function integer(x: number): boolean {
  return Number.isInteger(x);
}

function text(x: number): string {
  return x.toString() + " " + String(x);
}

function fixed(x: number, digits: number): string {
  return x.toFixed(digits);
}

function whole(x: number): string {
  return x.toFixed();
}

function parse(s: string): number {
  return Number.parseFloat(s);
}

const values = [0, -0, 1, -7, 0.5, 1e21, 2 ** 53, 1.5e300, NaN, Infinity, -Infinity, 5e-324];
console.log(values.map(integer));
console.log(values.map(text));

// Ties at the digit round away from zero only when the double is the tie itself: 1.005 is a hair
// below, 0.125 is exact.
console.log(fixed(1.005, 2), fixed(0.125, 2), fixed(2.5, 0), fixed(-2.5, 0), fixed(1.45, 1));
console.log(fixed(0, 2), fixed(-0, 2), fixed(-1e-10, 2), fixed(1e-10, 3), fixed(123.456, 0));
console.log(fixed(1e21, 2), fixed(-1.5e21, 1), fixed(NaN, 2), fixed(-Infinity, 1));
console.log(fixed(0.1, 20), fixed(1 / 3, 100).length, fixed(9.995, 2), whole(12.5));

const strings = [
  "3.5abc",
  "  \n\t42",
  "-.5",
  "+.5e1x",
  "1e",
  "1e+",
  "1e-2.5",
  ".e1",
  "",
  "   ",
  "-",
  "+-1",
  "0x10",
  "1_000",
  "Infinity",
  "-Infinityx",
  "infinity",
  "-0",
  "1e400",
  "1e-400",
  "00012.50",
];
console.log(strings.map(parse));
console.log(String(parse("-0")), String(1 / parse("-0")), parse("7") + parse("0.25"));

// toFixed decides a tie by the exact value of the double, carries into the integer part, takes the
// digits past the seventeen a double carries from its exact expansion, and coerces the digit count
// as ECMAScript does: NaN counts as zero, a fraction drops toward zero.
console.log(fixed(99.99, 1), fixed(0.5, 0), fixed(1.5, 0), fixed(-1.5, 0), fixed(1.25, 1));
console.log(fixed(0.5, 1), fixed(1.55, 1), fixed(8.125, 2), fixed(8.575, 2), fixed(0.6, 0));
console.log(fixed(0.06, 0), fixed(0.000001, 0), fixed(1234.5678, 3), fixed(1e15, 2));
console.log(fixed(1.45, 20), fixed(-0.0001, 2), fixed(Infinity, 2), fixed(-1e21, 0));
console.log(fixed(1.5, NaN), fixed(1.5, -0.5), fixed(1.5, 3.9));

// parseFloat reads the longest prefix the grammar takes: a point needs a digit on one side of it,
// and Infinity is spelled whole. The digits decide the last place of the double, a denormal
// included, and the whitespace skipped first is ECMAScript's, where U+0085 is not.
const prefixes = ["5.", "-5.", ".5", ".", "+.e3", "In", "+Infinity", "Infinityx", "12.5e2e3", "  -.5e-2xyz"];
const digits = ["3.14159265e41", "6.02214076e44", "1278572e37", "1800601e36", "5e-324", "1e-323"];
const denormals = ["2.2250738585072011e-308", "11111111111111111111e-19", "-1e-400", "0.1", "000123"];
const spaced = ["\u00A03", "\u20283", "\uFEFF3", "\u00853", "   3.5abc", "\u3000\uFEFF-1.5e3\u0661"];
console.log(prefixes.map(parse), digits.map(parse));
console.log(denormals.map(parse), spaced.map(parse));
