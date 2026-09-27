// A substitution of a template left open takes the rest of the file, and the missing `}` is
// reported at its end.
// expect: T1007 6:1 "expected `}`, found end of file"
const b = 1;
const t = `a${b
