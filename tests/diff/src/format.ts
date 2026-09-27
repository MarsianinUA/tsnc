// Format strings (requirements 3.9): a string first argument of console.log is read the way Node's
// util.format reads it, and every specifier converts its argument the way Node does. Most lines
// pass primitives; the last two pass arrays and an object.

function show(value: string | number | boolean | null | undefined): void {
  console.log("%s|%d|%i|%f|%j|%o|%O", value, value, value, value, value, value, value);
}

// Every specifier once, then the ones that take no argument or have none left.
console.log("%s|%d|%i|%f|%j|%o|%O|%c|%%", "a", "42", "12.9", "1.5e3", "q", "s", 7, "css");
console.log("%s %s", "only");
console.log("%x %s", "y");
console.log("trailing %", 1);
console.log("%%", 1);
console.log("%", 1);
console.log(1, "%s", 2);
console.error("%s=%d", "n", 42);

// Each specifier over the kinds of value a primitive can be.
show("text");
show("  0x1F  ");
show(" 3.25xyz");
show("1e21");
show("");
show(-0);
show(0.1);
show(1e21);
show(NaN);
show(-Infinity);
show(true);
show(false);
show(null);
show(undefined);

// %o and %O of a string quote it, escape what needs it, and pick the quote that saves an escape.
console.log("%O", "tab\there, a \"double\" quote");
console.log("%O", "it's");
console.log("%O", "it's \"both\"");
console.log("%O", "it's \"all\" `three`");
console.log("%o", "\u0000\u001f\u007f\u0085\\");
console.log("%O", "\ud800 lone and \ud83d\ude00 paired");

// A string longer than sixteen units that does not fit on the line breaks after each line end.
console.log("%O", "short line\nanother line that makes the string too long for one line of eighty");
console.log("%o", "no line end but still a long string that is well past eighty columns wide");

// %j of a string is JSON: control characters as \u00XX, a lone surrogate escaped.
console.log("%j", "q\"\\\b\f\n\r\t\u0001\ud800");

// The number specifiers read an array through its string: "1,2,3" parses as 1.
console.log("%d %i %f", [5], [1, [2, 3]], [-1.5]);
console.log("%j|%O", { a: 1 }, [1]);

// What is no specifier stays as it is, and a format string with nothing after it is not read at
// all. %c takes its argument and writes nothing; the arguments left over follow, a space each.
console.log("%% %s");
console.log("%c|%x|%%|%", "css", 1);
console.log("%s", "a", "b", 1);

// %s writes a primitive as String does but -0 as -0, and inspects an object to depth zero.
const shallow = [1, [2, [3]]];
console.log("%s %s %s %s %s %s", -0, null, undefined, true, shallow, { a: { b: 1 } });

function f(): void {}

function g(a: number, b: number): void {}

const h = (a: number): void => {};

// %d is Number(), %i parseInt, %f parseFloat, each of what the value is as a primitive. A function
// is NaN to %d.
console.log("%d %d %d %d %d %d %d %d %d", "0x10", " 12 ", "12px", [5], {}, true, null, -0, f);
console.log("%i %i %i %i %i", "0x1f", "12.9", "-0.5", 1e21, [7.5]);
console.log("%f %f %f", " 3.5abc", "x", [2.25]);

// Number() takes the whole text, less the whitespace around it, as one literal. An integer in
// radix 16, 8 or 2 has no sign, and past 53 bits a tie goes to the even neighbor.
let hexDigits = "0x";
let binaryDigits = "0b";
for (let i = 0; i < 300; i++) {
  hexDigits += "f";
  if (i < 60) {
    binaryDigits += "1";
  }
}
const numerals = [
  "", " 12 ", "+12", "-0", "1e3", ".5", "5.", "12e-1 ", "Infinity", "-Infinity", "12px", "1_0", ".",
  "1e", "infinity", "\u00a0 7\u2028", "\u00853", "0x10", "0X1f", "0o17", "0b101", "0x", "-0x1",
  "0x1g", "0b102", "0x1fffffffffffff", "0x20000000000001", "0x20000000000003", "0x200000000000011",
  binaryDigits, hexDigits,
];
for (const numeral of numerals) {
  console.log("%d", numeral);
}

// parseInt reads the longest integer prefix, and leading zeros are no significant digits.
let zeros = "";
let nines = "";
for (let i = 0; i < 400; i++) {
  zeros += "0";
  if (i < 320) {
    nines += "9";
  }
}
const integers = [
  "0x1f", "12.9", "-0.5", "-0", "  -12abc", "+7", "1e+21", "", "abc", "0x", "0xg", "  0x10z", "-0x10",
  "9007199254740993", "10000000000000000000000000000001", "123456789012345678901234567890",
  "0x20000000000003", "0x200000000000011", zeros + "1", nines,
];
for (const integer of integers) {
  console.log("%i", integer);
}

// %j is JSON: a key that holds undefined is left out, a function in an array is null and alone is
// undefined, and a cycle stops the whole value. A list thousands deep is written whole.
interface Link {
  self: Link | null;
  n: number;
}

const loop: Link = { self: null, n: 1 };
loop.self = loop;
console.log("%j %j %j %j", { c: [1, undefined, f], d: undefined, e: NaN, f: -0 }, undefined, f, "q\"\n");
console.log("%j %j", loop, { c: [[undefined]], d: undefined, e: NaN, f: 2 });
console.log("%j", "\u001f\udc00\ud83d\ude00");
let deep: Link | null = null;
for (let i = 3999; i >= 0; i--) {
  deep = { self: deep, n: i };
}
console.log("%j", deep);

// %o shows the hidden properties: a function's length, name and prototype, an array's length,
// which past 100 elements takes the place of "... more items".
const none: number[] = [];
const hundred: number[] = [];
for (let i = 0; i <= 100; i++) {
  hundred.push(i);
}
console.log("%o", g);
console.log("%o", h);
console.log("%o %o", [1, 2], none);
console.log("%o", { a: [g, h] });
console.log("%o", [[[[[g]]]]]);
console.log("%o", hundred);
