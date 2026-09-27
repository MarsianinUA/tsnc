// A block comment runs to its `*/`, so one left open takes the rest of the file with it.
// expect: T1004 3:14
const a = 1; /* never closed
console.log(a);
