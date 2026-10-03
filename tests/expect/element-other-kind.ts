// A narrow array flows into a wider array type as itself (requirements 3.6), so a push through the
// wide type can leave an element the narrow one does not allow. The read through the narrow type
// tests the tag and fails, where Node prints the string.
// stdout: 1
// stderr: error: an element holds a value its declared type does not allow at tests/expect/element-other-kind.ts:12:13
// exit: 1

const counts: number[] = [1];
const loose: (number | string)[] = counts;
console.log(counts[0]);
loose.push("two");
console.log(counts[1]);
