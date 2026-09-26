// A key may hold a lone surrogate, which the console prints as the escape Node prints, not as
// U+FFFD: the compiler keeps the unit the program wrote.

const odd = { "\ud800": 7, "a\udfffb": 8 };
console.log(odd);
console.log("%j", odd);
