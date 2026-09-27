// sort without a comparator (the Array methods of 2.2) orders the elements as strings, by UTF-16
// units: a number by its digits, both zeros as "0", so they keep their order, null as "null", an
// inner array as its join, and undefined last of all.

const digits = [10, 9, 1, 100, -1, 0.5];
const zeros = [0, -0];
const flags = [true, false];
const mixed = [undefined, "o", null, "m", undefined];
const lists = [[2], [1, 3], [1]];
console.log(digits.sort(), zeros.sort(), flags.sort());
console.log(mixed.sort(), lists.sort());

// U+00FF sorts below U+0100, and U+1F600 below U+FFFF: its first unit is a surrogate.
const words = ["\u0100", "\u00ff", "\uffff", "\u{1F600}", "a"];
console.log(words.sort().map((s) => s.charCodeAt(0)));
