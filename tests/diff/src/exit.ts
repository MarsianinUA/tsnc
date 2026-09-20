// process.exit with a code of its own. The program says nothing first, on purpose: Node writes to a
// pipe asynchronously on macOS, so output followed by process.exit can be cut off there, and that
// is a property of Node rather than of anything this corpus is testing. The programs that print
// end by running off the bottom instead.
//
// The code stays above 64. On Linux and macOS a program killed by a signal reports the signal's
// number where the exit code goes, and no signal is numbered that high, so a crash can never pass
// for the right answer. The runner refuses a corpus program that exits with 1..64.

function code(a: number, b: number): number {
  return 70 + ((a * b) % 11);
}

let total = 0;
for (let i = 1; i <= 4; i = i + 1) {
  total = total + i;
}

process.exit(code(total, 3));
