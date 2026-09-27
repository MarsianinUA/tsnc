// An open bracket does not swallow the rest of the file: a call, a destructuring and a call inside
// a function body left open each end with their line or at the `}` that closes the function, and
// the lines after them are read and reported as usual.
// expect: T1007 14:11
// expect: T1007 15:10
// expect: T2001 16:1
// expect: T2002 17:16
// expect: T2014 18:7
// expect: T1007 18:9
// expect: T1007 19:10
// expect: T2001 20:1
// expect: T1007 21:18
function foo(n: number): void {}
let x = 1 foo(
let y1 = ;
var z1 = 1
function g() { with (o) {} }
const { a, b
let y2 = ;
var z2 = 1
function f() { h(
}
let y3 = 1;
function h(n: number): void {}
