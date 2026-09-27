// Closures: counters with captured mutable state called from an array, a closure made on every pass
// of a loop, and a composed function applied many times.
const COUNTERS = 100;
const ROUNDS = 200000;
const MADE = 4000000;
const APPLIED = 10000000;

function counter(step: number): () => number {
  let count = 0;
  return () => {
    count += step;
    return count;
  };
}

function compose(f: (x: number) => number, g: (x: number) => number): (x: number) => number {
  return (x) => g(f(x));
}

function apply(times: number, f: (x: number) => number, start: number): number {
  let value = start;
  for (let i = 0; i < times; i++) {
    value = f(value);
  }
  return value;
}

const counters: (() => number)[] = [];
for (let i = 0; i < COUNTERS; i++) {
  counters.push(counter((i % 7) + 1));
}
let total = 0;
for (let round = 0; round < ROUNDS; round++) {
  for (const c of counters) {
    total += c();
  }
}

let made = 0;
for (let i = 0; i < MADE; i++) {
  const add = (y: number) => y + i;
  made += add(i % 10);
}

const twice = compose(
  (x) => x + 1,
  (x) => (x * 2) % 1000003,
);
console.log(total, made, apply(APPLIED, twice, 1));
