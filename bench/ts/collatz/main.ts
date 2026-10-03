// Collatz sequence lengths of every start below LIMIT: integer values in f64, with `%` and `/`.
const LIMIT = 1000000;

let total = 0;
let longest = 0;
let start = 0;
for (let n = 1; n < LIMIT; n++) {
  let x = n;
  let steps = 0;
  while (x !== 1) {
    x = x % 2 === 0 ? x / 2 : 3 * x + 1;
    steps++;
  }
  total += steps;
  if (steps > longest) {
    longest = steps;
    start = n;
  }
}
console.log(total, longest, start);
