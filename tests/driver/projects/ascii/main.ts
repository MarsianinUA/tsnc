// Each piece of a split is a one-unit string, a row of the static table the runtime borrows, so
// only the arrays take cells.
let total = 0;
for (let i = 0; i < 1000; i++) {
  total += "abcdefgh".split("").length;
}
console.log(total);
