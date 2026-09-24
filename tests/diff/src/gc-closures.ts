// Closures made in a loop (requirements 3.5, 6 and 10): the collector runs several times in the
// normal mode and on every allocation under TSNC_GC_STRESS, and a closure keeps what it captured
// through every collection. Each round makes counter pairs over one shared binding, closures over
// an object, an array and a long string, a comparator of its own and closures made inside map
// callbacks; a part of them is kept to the end and the rest becomes garbage at once.

interface Counter {
  inc: () => number;
  get: () => number;
}

function counter(start: number): Counter {
  let count = start;
  return { inc: () => ++count, get: () => count };
}

// The text doubles until it is wide, so a round allocates many bytes in few cells.
function banner(seed: string, width: number): () => string {
  let text = seed;
  while (text.length < width) {
    text = text + text;
  }
  return () => text.slice(0, 10) + text.length;
}

function direction(sign: number): (a: number, b: number) => number {
  return (a, b) => (a - b) * sign;
}

const counters: Counter[] = [];
const banners: (() => string)[] = [];
const tallies: (() => number)[] = [];
let checksum = 0;

for (let round = 0; round < 150; round++) {
  const pair = counter(round);
  pair.inc();
  pair.inc();
  checksum += pair.get();
  if (round % 4 === 0) {
    counters.push(pair);
  }

  const show = banner("round " + round + "; ", 12000);
  checksum += show().length;
  if (round % 3 === 0) {
    banners.push(show);
  }

  const box = { hits: 0, name: "box" + round };
  const values = [round % 7, round % 5, round % 3, 1];
  const tally = (): number => {
    box.hits++;
    return box.hits * 100 + values.length + box.name.length;
  };
  tally();
  if (round % 5 === 0) {
    tallies.push(tally);
  }

  const sorted = values.slice().sort(direction(round % 2 === 0 ? 1 : -1));
  checksum += sorted[0] * 10 + sorted[3];

  const adders = values.map((v) => (x: number) => x + v + round);
  checksum += adders.reduce((sum, add) => sum + add(1), 0);
}

let counted = 0;
for (const pair of counters) {
  pair.inc();
  counted += pair.get();
}
const tallied = tallies.map((tally) => tally());

console.log(checksum, counters.length, counted, counters[3].get(), counters[3].inc());
const last = banners[banners.length - 1];
console.log(banners.length, banners[0](), last(), tallied.slice(0, 5), tallied.length);
