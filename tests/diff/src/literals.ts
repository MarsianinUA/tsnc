// Literals (requirements 3.1 and 3.2): the value tsnc reads out of the source text is the one Node
// reads. A number in any radix, with separators or a point at either end, rounds to the nearest
// double and overflows to Infinity; a string or a template cooks its escapes.

console.log(0, 42, 1e21, 1E+21, 1.5e-7, 0.0000001, 0.1, .5, 5., 1.e2);
console.log(0x10, 0XfF, 0o17, 0b101, 1_000_000, 0x1_0, 1e1_0);
// 2^53 + 1 rounds to even and 2^64 - 1 up. The last three need every digit to decide the last place
// of the double.
console.log(9007199254740993, 0xFFFFFFFFFFFFFFFF, 1e400, 3.14159265e41, 6.02214076e44, 1278572e37);

// Any other character after a backslash is itself, a pair may be written as two escapes of either
// form, a lone surrogate stays as it is, and a backslash before a line end adds nothing.
console.log(['a', "b", '', "it's", '\b\f\n\r\t\v\0', '\'\"\\', '\x41\u0042\u{43}', '\a\$\q']);
console.log(['\u{1F600}', '\uD83D\uDE00', '\u{D83D}\u{DE00}', '\uD800x', '\uDE00\uD83D', 'a\
b']);
console.log([`$ \${x} $`, `\u0041\``, `a\
b`]);
