// Every loop of the subset and the two jumps out of one. A loop is where the IR grows a back edge
// and a phi, so each of these pins the shape lower builds: the header, the body, the latch and the
// exit.

function sum(n: number): number {
  let total = 0;
  for (let i = 1; i <= n; i = i + 1) {
    total = total + i;
  }
  return total;
}

function countdown(n: number): number {
  let steps = 0;
  while (n > 0) {
    n = n - 1;
    steps = steps + 1;
  }
  return steps;
}

// A do...while runs its body before it ever looks at the condition.
function atLeastOnce(n: number): number {
  let steps = 0;
  do {
    steps = steps + 1;
    n = n - 1;
  } while (n > 0);
  return steps;
}

function firstMultiple(of: number, over: number): number {
  for (;;) {
    over = over + 1;
    if (over % of === 0) {
      break;
    }
  }
  return over;
}

function sumOdd(limit: number): number {
  let total = 0;
  for (let i = 0; i < limit; i = i + 1) {
    if (i % 2 === 0) {
      continue;
    }
    total = total + i;
  }
  return total;
}

function grid(rows: number, columns: number): number {
  let cells = 0;
  for (let r = 0; r < rows; r = r + 1) {
    for (let c = 0; c < columns; c = c + 1) {
      if (c === 2) {
        break;
      }
      cells = cells + 1;
    }
  }
  return cells;
}

console.log(sum(10), sum(0), sum(1));
console.log(countdown(5), countdown(0), atLeastOnce(0), atLeastOnce(3));
console.log(firstMultiple(7, 1), sumOdd(10), grid(3, 5));

// The counter of a for loop keeps its value after the loop, and a loop that never runs leaves it
// where the initializer put it.
let seen = 0;
for (let i = 0; i < 4; i = i + 1) {
  seen = seen * 10 + i;
}
console.log(seen);

let never = 0;
while (never > 0) {
  never = never + 1;
}
console.log(never);
