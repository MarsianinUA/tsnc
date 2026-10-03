// A narrow array flows into a wider array type as itself (requirements 3.6), so a push through the
// wide type can leave an element the narrow one does not allow. A pop through the narrow type
// answers `string | undefined`, which holds no number: it tests the tag and fails, where Node
// prints 2.
// stderr: error: an element holds a value its declared type does not allow at tests/expect/pop-other-kind.ts:11:36
// exit: 1

const words: string[] = ["one"];
const loose: (string | number)[] = words;
loose.push(2);
const popped: string | undefined = words.pop();
console.log(popped);
