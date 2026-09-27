// Nesting has a limit, so that a deeply nested expression is a diagnostic rather than a stack
// overflow in the compiler. Past it the parser gives up on the rest of the file: the message stands
// on the token where the limit was reached, here the `1` inside 63 parentheses, and no other
// mistake of the parser is reported after it.
// expect: T1012 6:77 "the code nests too deeply"
const deep = (((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((1)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))));
let after = ;
