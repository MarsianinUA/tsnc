// A sort's comparator reads each element through the array's declared type, so an element that a
// push through a wider type left fails the second sort, and the failure names that sort rather than
// the first, which built a comparator of the same shape. Node sorts the mixed array.
// stdout: [ 1, 2 ]
// stderr: error: an element holds a value its declared type does not allow at tests/expect/sort-other-kind.ts:13:1
// exit: 1

const counts: number[] = [2, 1];
const loose: (number | string)[] = counts;
counts.sort((a, b) => a - b);
console.log(counts);
loose.push("three");
counts.sort((a, b) => b - a);
