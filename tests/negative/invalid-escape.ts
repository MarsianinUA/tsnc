// An escape the language does not define is reported, and the string goes on after it: a `\x`
// without two hex digits, a `\u` without four or with more than U+10FFFF, and the octal escapes,
// of which only `\0` before a non-digit is left.
// expect: T1006 13:13 "`\x4`"
// expect: T1006 14:13 "`\x`"
// expect: T1006 15:13 "`\u12`"
// expect: T1006 16:13 "`\u{}`"
// expect: T1006 17:13 "`\u{12`"
// expect: T1006 18:13 "`\u{110000}`"
// expect: T1006 19:13 "`\01`"
// expect: T1006 20:13 "`\1`"
// expect: T1006 21:13 "`\8`"
const e1 = '\x4';
const e2 = '\xg';
const e3 = '\u12';
const e4 = '\u{}';
const e5 = '\u{12';
const e6 = '\u{110000}';
const e7 = '\01';
const e8 = '\1';
const e9 = '\8';
