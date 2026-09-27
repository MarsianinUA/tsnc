// After a syntax error the parser finds the next statement and goes on, so one run reports every
// mistake of the file. What it kept of a broken statement is checked like any other code: the
// body of the broken `if` still calls `b`, which is a number, and the `var` it refused declares
// nothing, so `c` is a name nobody declared. `f` is read before its `let`, but its initializer
// already failed, so its type is the error type and nothing more is said about it.
// expect: T1007 14:9
// expect: T1007 16:7
// expect: T2001 17:1
// expect: T1007 18:7
// expect: T3006 18:9
// expect: T2009 20:1
// expect: T1009 21:11
// expect: T4008 21:19
let a = ;
let b = 1
f(1, 2;
var c = 3
if (a { b() }
let d = 4
class E {}
let f = a ?? b || c
let g = 5
