// A write at `length` appends (requirements 3.8). A write past it would leave a hole, and it is a
// runtime error, where Node makes the array sparse.
// stdout: [ 1, 2 ]
// stderr: error: index out of range at tests/expect/array-write.ts:10:1
// exit: 1

const values = [1];
values[1] = 2;
console.log(values);
values[3] = 4;
console.log(values);
