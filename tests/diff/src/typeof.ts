// `typeof` on a value whose type is already known: check types the operator as the union of the
// words it can answer, and since the operand has one static type the answer is a constant. Nothing
// is read at run time, so this pins the word the compiler chose against the one Node computes.

function ofNumber(x: number): string {
  return typeof x;
}

function ofString(x: string): string {
  return typeof x;
}

function ofBoolean(x: boolean): string {
  return typeof x;
}

const nothing = undefined;
const empty = null;

console.log(typeof 1, typeof "text", typeof true);
console.log(typeof nothing, typeof empty);
console.log(ofNumber(42), ofString("text"), ofBoolean(false));
console.log(typeof NaN, typeof Infinity);
