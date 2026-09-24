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
