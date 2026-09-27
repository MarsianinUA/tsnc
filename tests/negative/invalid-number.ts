// A number literal is one token however it is misspelled, so a mistake in it is one diagnostic: a
// radix prefix with no digits or with a digit it does not take, an exponent with no digits, an `_`
// that is not between two digits, a leading zero, and a name or a `n` glued to the end.
// expect: T1005 18:12
// expect: T1005 19:12
// expect: T1005 20:12
// expect: T1005 21:12
// expect: T1005 22:12
// expect: T1005 23:12
// expect: T1005 24:12
// expect: T1005 25:12
// expect: T1005 26:12
// expect: T1005 27:13
// expect: T1005 28:13
// expect: T1005 29:13
// expect: T1005 30:13
// expect: T1005 31:13
const n1 = 0x;
const n2 = 0x_1;
const n3 = 0b2;
const n4 = 1e;
const n5 = 1e+;
const n6 = 1_;
const n7 = 1__0;
const n8 = 1_.5;
const n9 = 1._5;
const n10 = 0_1;
const n11 = 010;
const n12 = 08;
const n13 = 3in;
const n14 = 10n;
