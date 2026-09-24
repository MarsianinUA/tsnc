// `do...while` (requirements 2.2): the body runs before the first test, `continue` jumps to the
// test rather than to the top of the body, `break` leaves at once, the test may have effects of its
// own, and loops nest.

function once(again: boolean): number {
  let runs = 0;
  do {
    runs++;
  } while (again && runs < 3);
  return runs;
}

function collatz(start: number): number {
  let n = start;
  let steps = 0;
  do {
    n = n % 2 === 0 ? n / 2 : 3 * n + 1;
    steps++;
  } while (n !== 1);
  return steps;
}

// Once i reaches the limit, `continue` goes to the test, which is false: the loop ends. Were it to
// go to the top of the body, it would never end.
function skipTail(limit: number): string {
  let i = 0;
  let seen = "";
  do {
    i++;
    if (i >= limit) {
      continue;
    }
    seen += i;
  } while (i < limit);
  return seen + "|" + i;
}

function firstOver(values: number[], bound: number): number {
  let index = -1;
  do {
    index++;
    if (values[index] > bound) {
      break;
    }
  } while (index < values.length - 1);
  return index;
}

let checks = 0;
function more(n: number, bound: number): boolean {
  checks++;
  return n < bound;
}

let k = 0;
do {
  k += 2;
} while (more(k, 7));

function table(rows: number, columns: number): string {
  const lines: string[] = [];
  let r = 0;
  do {
    let line = "";
    let c = 0;
    do {
      c++;
      if (c === 3) {
        continue;
      }
      line += r * c + " ";
    } while (c < columns);
    lines.push(line.trim());
    r++;
  } while (r < rows);
  return lines.join(" / ");
}

console.log(once(false), once(true), collatz(1), collatz(27), skipTail(5));
console.log(firstOver([1, 5, 9, 12], 8), firstOver([1, 2], 8), k, checks);
console.log(table(3, 4));
