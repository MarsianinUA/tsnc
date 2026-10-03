// Numbers opt proves whole become 32 or 64 bit integers at -o:speed, and print what Node prints:
// across 2^31, next to 2^53 where f64 stops counting by one, and at -0, which no integer holds.

// Across 2^31 a 32 bit counter would wrap.
function sumAcross(from: number): number {
  let total = 0;
  for (let i = from; i < from + 16; i++) {
    total += i * 3;
  }
  return total;
}
console.log(sumAcross(2147483640), sumAcross(-2147483656));

// Past 2^53 f64 rounds x + 1 back down, and an integer would not.
function stepPast(start: number): number[] {
  const out: number[] = [];
  let x = start;
  for (let k = 0; k < 4; k++) {
    x = x + 1;
    out.push(x);
  }
  return out;
}
console.log(stepPast(9007199254740990), stepPast(-9007199254740994));

// -0 comes out of a remainder of a negative, a negation and a product with 0.
function signs(n: number): number[] {
  const out: number[] = [];
  for (let i = -n; i <= n; i++) {
    out.push(i % 2, -i, i * 0, 0 * -i, (i % 3) + 0);
  }
  return out;
}
console.log(signs(3));

// Shifts by 0, 31, 32 and 33, which count modulo 32, and unsigned shifts of negatives.
function shifts(from: number): number[] {
  const out: number[] = [];
  for (let x = from; x <= -from; x++) {
    out.push(x << 0, x << 31, x << 32, x << 33, x >> 31, x >> 33);
    out.push(x >>> 0, x >>> 31, x >>> 32, x >>> 33, (x >>> 0) + 1, (x >> 1) - 1);
    out.push(~x, ~x + 1, x & 5, -x | 8, x ^ -1);
  }
  return out;
}
console.log(shifts(-3));

// Halves rounded three ways; ceil and trunc of -0.5 are -0.
function halves(n: number): number[] {
  const out: number[] = [];
  for (let i = -n; i <= n; i++) {
    const down = Math.floor(i / 2);
    const up = Math.ceil(i / 2);
    out.push(down, down + 1, up, up + 1, Math.trunc(i / 2), Math.abs(i) + 1);
  }
  return out;
}
console.log(halves(5));

// A string hash wraps through | 0 on every step.
function hash(text: string): number {
  let h = 0;
  for (let i = 0; i < text.length; i++) {
    h = (h * 31 + text.charCodeAt(i)) | 0;
  }
  return h;
}
console.log(hash("the quick brown fox jumps over the lazy dog"), hash(""), hash("zzzzzzzzzzzz"));

// A global every store keeps below 2^31, whose product before the remainder needs 64 bits.
let seed = 11;
function next(): number {
  seed = (seed * 16807) % 2147483647;
  return seed;
}
const draws: number[] = [];
for (let k = 0; k < 6; k++) {
  draws.push(next() % 100, next());
}
console.log(draws, seed);

// A parameter narrows from what its direct calls pass; NaN and a fraction reach this one, so a
// comparison's false side says nothing about it.
function clampFloor(x: number): number {
  if (x < 0) {
    return 0;
  }
  if (x > 10) {
    return 10;
  }
  return Math.floor(x) + 1;
}
console.log(clampFloor(0 / 0), clampFloor(3.7), clampFloor(-2), clampFloor(12), clampFloor(10));

function triple(n: number): number {
  return n * 3 + 1;
}
const tripled: number[] = [];
for (let i = -2; i < 3; i++) {
  tripled.push(triple(i), triple(i * 1000003));
}
console.log(tripled);

// x % ±2^k: every finite x exactly, NaN for NaN and the infinities, and the sign of x on a zero.
const dividends: number[] = [0, -0, 0 / 0, 1 / 0, -1 / 0, 5e-324, -5e-324, 1e308, -1e308];
dividends.push(2 ** 53 + 2, 2.5, -2.5, 7, -7, -4, 1023.75, -4096.25, 4503599627370497);
for (const x of dividends) {
  console.log(x, x % 1, x % 2, x % -2, x % 1024, x % 4503599627370496, x % 0.5);
}

// A field, an element and a parameter of a function value are whole when every store or call
// keeps them so. One fraction, -0 or NaN through any place of the same shape takes that away.
interface Counter {
  n: number;
  step: number;
}
interface Cell {
  v: number;
}
function counted(rounds: number): number[] {
  const c: Counter = { n: 0, step: 3 };
  const hist: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < rounds; i++) {
    c.n = (c.n + c.step) % 8;
    hist[c.n] += 1;
  }
  return hist;
}
console.log(counted(21));

function zeroed(cell: Cell): void {
  cell.v = -0;
}
const zero: Cell = { v: 4 };
const doubled: Cell = { v: 1 };
for (let k = 0; k < 40; k++) {
  doubled.v = doubled.v * 2 + 1;
}
zeroed(zero);
console.log(zero.v, 1 / (zero.v * 2), [7, 8][zero.v], doubled.v, doubled.v + 1);

function halve(values: number[]): void {
  values[0] = 0.5;
}
const evens: number[] = [];
for (let i = 0; i < 4; i++) {
  evens.push(i * 2);
}
halve([1, 2]);
console.log(evens.map((x) => x * 3), evens[1] % 3);

const byValue: number[] = [5, 1, 4, 2, 3];
const byFraction: number[] = [1.75, 2.25, 3.5];
byValue.sort((x, y) => x - y);
// A direct call alone would make the parameters whole.
function byFractionalPart(x: number, y: number): number {
  let d = 0;
  if (x % 1 !== y % 1) {
    d = (x % 1) - (y % 1);
  }
  return d;
}
byFraction.sort(byFractionalPart);
console.log(byValue, byFraction, byFractionalPart(1, 2));

type Three = (a: number, b: number, c: number) => number;
function apply3(f: Three, a: number, b: number, c: number): number {
  return f(a, b, c);
}
function wrap(a: number, b: number, c: number): number {
  return (a + b + c) % 7;
}
const pick: Three = (a, b, c) => {
  let r = 0;
  if (a > b) {
    r = a + c;
  }
  return r;
};
console.log(wrap(1, 2, 3), apply3(wrap, 3, 9, 1), apply3(wrap, 2.5, 1, 0));
console.log(apply3(wrap, 0 / 0, 1, 0));
console.log(apply3(pick, 2.5, 1, 0), apply3((a, b, c) => a * b * c, -0, 3, 1));

let tally = 0;
let share = 1;
const bump = (): number => {
  tally = (tally + 3) % 10;
  share = share / 2;
  return tally + share;
};
console.log(bump(), bump(), bump());
