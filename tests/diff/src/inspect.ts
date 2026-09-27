// How console.log shows an array or an object (requirements 3.9), as Node's util.inspect does:
// nesting past depth two prints the kind, more than six numbers group into right-aligned columns
// and other entries into left-aligned ones, a string takes the quote it need not escape and breaks
// after its line ends, long values are cut, fields print in table order, and a cycle prints as a
// reference.

// repeat builds by doubling: adding one unit at a time copies the string 10,000 times, and under GC
// stress each copy collects.
function repeat(unit: string, count: number): string {
  let out = "";
  let block = unit;
  for (let n = count; n > 0; n = Math.floor(n / 2)) {
    if (n % 2 === 1) {
      out += block;
    }
    block += block;
  }
  return out;
}

console.log([1, 2, 3]);
console.log([true, false]);
console.log(["a", "b"]);
console.log([1, "x", null, undefined, true, -0]);

const none: number[] = [];
const deepest: number[][][][] = [[[[]]]];
console.log([[1, [2, [3, [4]]]]]);
console.log({ a: { b: { c: { d: 1 } } } });
console.log([none, {}, deepest]);

const thirty: number[] = [];
const sevens: number[] = [];
const zeros: number[] = [];
for (let i = 0; i < 120; i++) {
  if (i < 30) {
    thirty.push(i + 1);
  }
  if (i <= 100) {
    zeros.push(0);
  }
  sevens.push(i * 7);
}
console.log(thirty);
console.log(sevens);
console.log(zeros);

// A wide character takes two columns.
console.log(["a", "bb", "ccc", "dddd", "e", "f", "g"]);
console.log(["\u4e2d\u6587", "\u65e5\u672c\u8a9e", "ab", "\ud55c\uad6d\uc5b4", "x", "\u5b57", "yy"]);

console.log(["it's", "it's \"x\"", "it's \"x\" ${y}", "plain"]);
console.log(["a\nb\tc\x00\x7f\x9f\\\b\f\r\x0b", "\ud800", "x\udc00", "\u{1F600}"]);

const long = "line one of text\nline two of text\nline three of text that is long enough to break";
console.log([long]);
console.log("%O", long);
console.log("%O", repeat("a", 10002));

// Integer-like keys come first, ascending; a key that is no identifier is quoted. A field that is
// optional and was never set is not there; a required one that holds undefined is.
interface Maybe {
  x: number;
  y?: number;
}

interface Held {
  x: number;
  y: number | undefined;
}

const unset: Maybe = { x: 1 };
const held: Held = { x: 1, y: undefined };
console.log({ b: 1, "2": "x", "1": "y", a: 3 });
console.log({ "a-b": 1, $d: 2, "\u043a\u043b\u044e\u0447": 4 });
console.log(unset, held);

interface Self {
  self: Self | null;
  n: number;
}

const ring: unknown[] = [1];
ring.push(ring);
const own: Self = { self: null, n: 1 };
own.self = own;
console.log(ring);
console.log(own);

// Entries that do not fit in the break length together take a line each.
const wide = { a: repeat("a", 30), b: repeat("b", 30), c: 1 };
console.log([wide, [wide]]);
