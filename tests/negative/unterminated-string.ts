// A string ends at the end of its line. A quote left open there is reported, the string holds what
// stood before the line break, and the next line is read as code again, mistakes and all. A
// template literal is the way to write text across lines.
// expect: T1002 7:9
// expect: T1002 9:11
// expect: T2001 10:1
let s = 'abc
let n = 1;
const t = 'a
var x;
