// The parser reports at most one syntax error per line, since the first one usually explains the
// rest: the `+ ;` after `)`, and the names after `a` in a call that lacks its commas. A mistake of
// another kind on the same line is still reported, and so is one at the start of the line, before
// the statement that follows it.
// expect: T1007 15:10
// expect: T1007 16:5
// expect: T1008 17:1
// expect: T1007 18:10
// expect: T2007 18:14
// expect: T2001 19:1
// expect: T1007 19:10
// expect: T2007 19:14
function f(n: number): void {}
const a = 1;
let x1 = ) + ;
f(a b c d)
) let x2 = 1
let x3 = ) + eval
var x4 = ) + eval
