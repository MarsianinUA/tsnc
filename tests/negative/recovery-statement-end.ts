// A broken statement ends where the next one starts: a call left open stops at the `let` of the
// next line, which is then read whole; `(x)` followed by a line that starts with `=>` is two
// statements and a stray `=>`; and a parenthesis left open inside a function body stops at the
// `;`, so the `return` after it and the next line are read as they are.
// expect: T1007 12:7
// expect: T1008 15:1
// expect: T1007 16:26
function f(a: number, b: number): void {}
const a = 1;
const b = 2;
const x = 3;
f(a, b
let y = 2;
(x)
=> 1
function g() { let z = (1; return z }
let w = 1;
