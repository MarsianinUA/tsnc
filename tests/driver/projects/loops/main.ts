// Numbers and loops, the done criterion of T4.5, reported without printing a number: the runtime
// answers a number with a panic until T4.6 writes rt/num.

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
