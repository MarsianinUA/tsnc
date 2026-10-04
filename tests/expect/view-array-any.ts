// An `any` given to an array type the program only reads through (requirements 3.6) is checked
// where it is used: a loop over it tests the layout of the cell, and an object fails there, where
// Node throws a TypeError.
// stdout: start 1
// stderr: error: a value holds a kind its type does not allow at tests/expect/view-array-any.ts:14:3
// exit: 1

function make(): any {
  return { a: 0 };
}

function count(items: (number | string)[]): number {
  let n = 0;
  for (const item of items) {
    n += typeof item === "number" ? 1 : 0;
  }
  return n;
}

const counts: number[] = [1];
console.log("start", count(counts));
console.log(count(make()));
