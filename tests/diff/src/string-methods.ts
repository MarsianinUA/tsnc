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

compare("apple", "banana");
compare("same", "same");
compare("Z", "a");
compare("", "a");
compare("\u00e9", "e\u0301");

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
