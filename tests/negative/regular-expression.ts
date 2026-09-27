// Regular expressions are not supported in v1: use the string methods. A literal is one error,
// with flags or without, and `\d` inside it is not an unexpected character of its own.
// expect: T2020 7:16
// expect: T2020 8:15
// expect: T2020 9:17
// expect: T2020 10:13
const digits = /[0-9]+/;
const digit = /\d+/;
const flagged = /ab+c/i;
console.log(/ab+c/g);
