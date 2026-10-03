// What a string can do beyond being printed (requirements 3.2 and the String methods of 2.2):
// joining with `+` and in a template, comparing by UTF-16 units, reading one unit by index, the
// methods, String(x), toString, toFixed and parseFloat, and for...of, which takes a surrogate pair
// as one code point.

function compare(a: string, b: string): void {
  console.log(a, b, a === b, a !== b, a < b, a > b, a <= b, a >= b);
}

function isEmpty(text: string): boolean {
  return !text;
}

const greeting = "Hello";
const name = "World";
const joined = greeting + ", " + name + "!";
let built = "";
for (let i = 0; i < 3; i++) {
  built += i;
  built += "-";
}
console.log(joined, built, joined.length, "" + 1.5 + true + [1, 2], 1 + 2 + "3");
console.log(`${greeting} ${name.length} ${[1, 2, 3]} ${{ a: 1 }} ${0.1 + 0.2} ${false}`);

// An array in a chain of `+` turns into a string where `+` asks, before the call to its right runs,
// and the length of a chain counts it the same way. A `+=` in a loop appends in place where nothing
// else sees the variable: a copy taken before the loop, one a function keeps, a nested loop and
// `s += s` keep their text.
const items = [1, 2];
const grow = (): number => items.push(items.length + 1);
console.log(items + ":" + grow() + ":" + items, `${items}|${grow()}|${items}`);
console.log((items + ":" + grow()).length, `${items}${0.5}`.length, (greeting + "").length, ``.length);

function repeat(unit: string, count: number): string {
  let text = unit + "-";
  const before = text;
  for (let i = 0; i < count; i++) {
    text += unit + i;
    if (text.length > 40 && text[0] === unit) {
      text += "|";
    }
  }
  return before + " " + text;
}
console.log(repeat("a", 30), repeat("b", 0));

let doubled = greeting + "!";
for (let round = 0; round < 3; round++) {
  for (let i = 0; i < 2; i++) {
    doubled += doubled.length;
  }
  doubled += doubled;
}
const trail: string[] = [];
let step = name + "";
for (let i = 0; i < 20; i++) {
  step += i;
  trail.push(step);
}
let mark = name + "#";
const marks: string[] = [];
function remember(): void {
  marks.push(mark);
}
for (let i = 0; i < 3; i++) {
  mark += i;
  remember();
}
console.log(doubled.length, doubled.slice(0, 24), trail[3], trail[19].length, marks.join(" "));

compare("apple", "banana");
compare("same", "same");
compare("Z", "a");
compare("", "a");
compare("\u00e9", "e\u0301");
compare("ab", ["a", "b"].join(""));

// A literal of one unit or none on either side: a unit past ASCII, half a pair, a longer string
// that starts with the unit.
for (const c of ["a", "b", "", "ab", "ba", "\xe9", "e\u0301", "\u{1F600}"[0]]) {
  console.log(c === "a", "a" !== c, c === "", "" !== c, c === "\xe9", "\uD83D" === c);
}

console.log(joined[0], joined[joined.length - 1], name.charCodeAt(1), name.charCodeAt(9));
console.log(joined.slice(7), joined.slice(-6, -1), joined.slice(3, 1), joined.slice());
console.log(joined.indexOf("o"), joined.indexOf("o", 5), joined.indexOf("z"));
console.log(joined.includes("World"), joined.includes("world"), joined.includes(""));
console.log("a,b,,c".split(","), "a,b,c".split(",", 2), "abc".split(""), "x".split("x"));
console.log("  padded \t".trim(), "MiXeD".toUpperCase(), "MiXeD".toLowerCase());
console.log(joined.startsWith("Hello"), joined.startsWith("World", 7), joined.endsWith("!"));
console.log(joined.endsWith("Hello", 5), joined.endsWith("x"));

console.log(String(), String(42), String(true), String([1, [2, 3]]), String("s"));
console.log((255).toString(), (1 / 3).toFixed(4), (2.5).toFixed(), (-1.005).toFixed(2));
console.log(Number.parseFloat("  3.25abc"), Number.parseFloat("x"), Number.parseFloat("-0"));

for (const c of "a\u{1F600}b") {
  console.log(c, c.length);
}

const words = ["delta", "alpha", "charlie"];
let first = words[0];
for (const w of words) {
  if (w < first) {
    first = w;
  }
}
console.log(first, words.join(" < "), isEmpty(""), isEmpty("a"));

// Every method counts in UTF-16 units, and a position goes through ToIntegerOrInfinity first: a
// fraction goes toward zero and NaN is 0. A piece that may hold half a pair prints as its units.
function units(text: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    out.push(text.charCodeAt(i));
  }
  return out;
}

function glue(a: string, b: string): string {
  return a + b;
}

const mixed = glue("a\u{1F600}", "\u041f\u0440\u0438\u0432\u0435\u0442");
compare(mixed, glue("a\u{1F600}\u041f\u0440\u0438\u0432", "\u0435\u0442"));
compare(mixed, mixed.slice(0, 8));
compare("\u0100", "\u00ff");
compare("\u{1F600}", "\uffff");
compare("\uffff", "\u{10000}");
compare("ab", "abc");

const positions = [0, 1, 2, 3, 8, -0.5, -1e-300, NaN, 2.9, 9, -1, Infinity, -Infinity];
console.log(positions.map((p) => mixed.charCodeAt(p)));
const starts = [-3, -1.9, 1.9, NaN, 1, 2, 0, 3, 9, -Infinity, 0];
const ends = [Infinity, Infinity, 3, 2, 2, 3, NaN, 1, Infinity, Infinity, 9];
for (let i = 0; i < starts.length; i++) {
  console.log(starts[i], ends[i], units(mixed.slice(starts[i], ends[i])));
}
console.log(units(mixed.slice(-3)), units(mixed[1]), units(mixed[3]), units(mixed[-0]));

// for...of takes a pair whole and a lone surrogate of either half by itself.
const steps: number[][] = [];
for (const c of "a\u{1F600}\uD800b\uDC00") {
  steps.push(units(c));
}
for (const c of "a\uD83D") {
  steps.push(units(c));
}
console.log(steps);

// An empty search is found where the position, clamped to the length, points.
const abc = glue("a", "bc");
console.log(abc.indexOf("b", 0), abc.indexOf("b", 2), abc.indexOf("bc", 1.9), abc.indexOf("abcd", 0));
console.log(abc.indexOf("c", Infinity), abc.indexOf("c", -Infinity), abc.indexOf("", 10), abc.indexOf("", NaN));
console.log(abc.startsWith("b", 1), abc.startsWith("c", 10), abc.startsWith("", 10), abc.startsWith("a", -5));
console.log(abc.startsWith("abcd", 0), abc.endsWith("b", 2), abc.endsWith("c", Infinity), abc.endsWith("c", 10));
console.log(abc.endsWith("c", NaN), abc.endsWith("", NaN), abc.endsWith("abcd", Infinity));

// The whitespace of ECMAScript: U+0085 has the Unicode property but is not in it, and U+200B is a
// format character.
const padded = "\uFEFF\u00A0\u2028\u3000 \t\n\v\f\rx y\u3000\u2029";
console.log("[" + padded.trim() + "]", units("\u0085\u200Bx\u200B\u0085".trim()));

// A limit goes through ToUint32: a fraction toward zero, the rest modulo 2^32, NaN and the
// infinities to 0. An empty separator splits a pair into its halves.
console.log("".split(""), "".split(","), "aaa".split("aa"), ",a,,b,".split(","), ",a,".split(","));
console.log("abc".split("", 2), "a--b--".split("--"), "ab".split("abc"), "a,b".split(",", -1));
for (const limit of [0, 1.9, -1, 4294967296, 4294967297, Infinity, NaN]) {
  console.log(limit, "a,b,c".split(",", limit));
}
console.log("\u{1F600}x".split("").map(units));
for (const start of [2.9, -2.9, -1, -10, 10, NaN, Infinity, -Infinity, -0]) {
  console.log(start, "abcde".slice(start).length);
}

// Every one-unit string below 128 reads the same whichever way a text is taken apart, and so do
// the first units past ASCII and the halves of a pair.
const table = [
  "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f",
  "\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f",
  "\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f",
  "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f",
  "\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f",
  "\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f",
  "\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f",
  "\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f",
  "\u0080\u00ff\u{1F600}",
].join("");
const byIndex: number[] = [];
const bySlice: number[] = [];
for (let i = 0; i < table.length; i++) {
  byIndex.push(table[i].charCodeAt(0));
  bySlice.push(table.slice(i, i + 1).charCodeAt(0));
}
const byCodePoint: number[] = [];
for (const c of table) {
  byCodePoint.push(c.charCodeAt(c.length - 1));
}
const bySplit = table.split("").map((c) => c.charCodeAt(0));
console.log(byIndex.join(","));
console.log(byCodePoint.join(","));
console.log(bySlice.join(",") === byIndex.join(","), bySplit.join(",") === byIndex.join(","));
console.log(table[65] + table[66], table[65] === "A", table[0] === "\x00", table.length);
