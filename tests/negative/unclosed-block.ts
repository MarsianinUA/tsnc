// A block left open takes the rest of the file, and the missing `}` is reported at its end.
// expect: T1007 4:1 "expected `}`, found end of file"
function f() {
