// A `let` or `const` exists from the start of its block but holds nothing until its declaration
// runs, so this read, which runs right where it stands, finds nothing to read; Node throws a
// ReferenceError here. A function may name it earlier, as long as it is called after.
// expect: T3028 6:13
const scale = 2;
console.log(total * scale);
const total = 10;
