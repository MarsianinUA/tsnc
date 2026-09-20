// Numbers and loops, the done criterion of T4.5, reported through a boolean and an exit code. The
// digits of a printed number are compared with Node in the differential corpus of T4.7.

function sum(n: number): number {
  let total = 0;
  for (let i = 1; i <= n; i = i + 1) {
    total = total + i;
  }
  return total;
}

const total = sum(10);
console.log(total === 55);
process.exit(total % 7);
