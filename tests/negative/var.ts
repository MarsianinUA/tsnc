// `var` is never supported: requirements 2.2, "Never". Every declaration is reported, so the
// parser does not stop at the first one.
// expect: T2001 5:1
// expect: T2001 6:1
var count = 1;
var step = 2;
