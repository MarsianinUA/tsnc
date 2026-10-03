// An array of records: built by push, sorted by a comparator, then filter, map and reduce over their
// fields. The id tie-break makes the order total, so a stable and an unstable sort agree.
interface Item {
  id: number;
  x: number;
  y: number;
  name: string;
}

const COUNT = 200000;
const ROUNDS = 3;

let seed = 11;
function next(): number {
  seed = (seed * 16807) % 2147483647;
  return seed;
}

let checksum = 0;
for (let round = 0; round < ROUNDS; round++) {
  const items: Item[] = [];
  for (let i = 0; i < COUNT; i++) {
    items.push({ id: i, x: next() % 10000, y: next() % 10000, name: "item" + (i % 100) });
  }
  items.sort((a, b) => (a.x !== b.x ? a.x - b.x : a.id - b.id));

  const near = items.filter((p) => p.x < 5000 && p.y < 5000);
  const total = near.map((p) => p.x + p.y).reduce((sum, v) => sum + v, 0);
  let weighted = 0;
  for (let i = 0; i < items.length; i++) {
    weighted += items[i].id * (i % 7);
  }
  let named = 0;
  for (const p of near) {
    if (p.name === "item42") {
      named++;
    }
  }
  checksum += near.length + total + weighted + named;
}
console.log(checksum);
