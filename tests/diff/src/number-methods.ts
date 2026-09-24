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
