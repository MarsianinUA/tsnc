// A binary search and a hash over a number[]: bitwise operators on numbers opt cannot prove whole.
const SIZE = 1000000;
const SEARCHES = 5000000;
const ROUNDS = 60;

function find(a: number[], key: number): number {
  let lo = 0;
  let hi = a.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const v = a[mid];
    if (v === key) {
      return mid;
    }
    if (v < key) {
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return -1;
}

const a: number[] = [];
for (let i = 0; i < SIZE; i++) {
  a.push(i * 2);
}

let found = 0;
for (let i = 0; i < SEARCHES; i++) {
  found += find(a, (i * 7) % (2 * SIZE));
}

let h = 0;
for (let r = 0; r < ROUNDS; r++) {
  for (let i = 0; i < a.length; i++) {
    h = (h * 31 + a[i]) | 0;
  }
}
console.log(found, h);
