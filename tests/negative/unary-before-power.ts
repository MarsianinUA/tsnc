// The left side of `**` cannot be a unary expression, since `-2 ** 2` reads as either `(-2) ** 2`
// or `-(2 ** 2)`. Parentheses settle it, and `++a`, a negative right side and a parenthesized left
// side are fine. The parser keeps the expression, so its type is still checked: `typeof a` and
// `!a` are no numbers.
// expect: T1010 11:12
// expect: T1010 12:12
// expect: T3003 12:12
// expect: T1010 16:12 "unary `!` expression"
// expect: T3003 16:12
let a = 2;
const r1 = -2 ** 2;
const r2 = typeof a ** 2;
const r3 = (-2) ** 2;
const r4 = 2 ** -2;
const r5 = ++a ** 2;
const r6 = !a ** 2;
