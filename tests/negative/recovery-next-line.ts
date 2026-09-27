// A syntax error never hides one on the next line: the error that finds a line break reports at
// the end of its own line, and the next line starts over. What each broken line kept is still
// checked: `++f()` calls a number, and `const x` has neither a type nor a value.
// expect: T1009 17:11
// expect: T1007 18:10
// expect: T1011 19:3
// expect: T3006 19:3
// expect: T1007 20:10
// expect: T1007 21:13
// expect: T1007 22:10
// expect: T3008 23:7
// expect: T1007 23:8
// expect: T1007 24:5
let a: number | undefined = 1;
let b = 2;
let c = 3;
let f = a ?? b || c
let g1 = ;
++f()
let g2 = ;
import { h }
let g3 = ;
const x
foo(;
function foo(n: number): void {}
