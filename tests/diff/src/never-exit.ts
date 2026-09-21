// The never side of a ternary, taken: the program leaves through the process.exit inside it. It
// prints nothing first and exits above 64, for the reasons exit.ts gives.

function positive(n: number): number {
  return n > 0 ? n : process.exit(70);
}

positive(-3);
