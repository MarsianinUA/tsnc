// process.exit reduces its code the way ToInt32 does, so 2^32 + 73 leaves with 73 on every system.
// That keeps the code above 64, and the program prints nothing first, for the reasons exit.ts
// gives.

function code(base: number): number {
  return base + 73;
}

process.exit(code(4294967296));
