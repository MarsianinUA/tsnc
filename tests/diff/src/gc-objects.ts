// Objects allocated in a loop (requirements 6 and 10): the collector runs several times in the
// normal mode and on every allocation under TSNC_GC_STRESS, and what the program still reaches
// comes through intact. A tree built at the start lives through the whole run while short-lived
// trees come and go around it; a ring of records with strings, arrays and optional fields has its
// slots replaced round-robin, so the garbage is interleaved with cells still in use. Strings grow
// by doubling and arrays come whole out of map, split and slice: few allocations, many bytes, so
// the normal mode collects often while the stress mode, which collects on every allocation, stays
// quick.

interface Tree {
  left: Tree | null;
  right: Tree | null;
  depth: number;
}

function build(depth: number): Tree {
  if (depth === 0) {
    return { left: null, right: null, depth };
  }
  return { left: build(depth - 1), right: build(depth - 1), depth };
}

function check(tree: Tree | null): number {
  if (tree === null) {
    return 0;
  }
  return 1 + check(tree.left) + check(tree.right);
}

interface Record {
  id: number;
  name: string;
  tags: string[];
  samples: number[];
  note?: string;
  neighbor: Record | null;
}

function widen(text: string, width: number): string {
  let out = text;
  while (out.length < width) {
    out = out + out;
  }
  return out;
}

const template: number[] = [];
for (let i = 0; i < 160; i++) {
  template.push(i % 13);
}

function record(id: number, neighbor: Record | null): Record {
  const samples = template.map((v, i) => v * (id % 17) + i);
  const tags = ("red,green," + id).split(",");
  const made: Record = { id, name: widen("r" + id + ";", 6000), tags, samples, neighbor };
  if (id % 3 === 0) {
    made.note = "every third " + id;
  }
  return made;
}

function weigh(r: Record): number {
  let weight = r.id + r.name.length + r.samples[r.id % r.samples.length];
  for (const tag of r.tags) {
    weight += tag.length;
  }
  if (r.note !== undefined) {
    weight += r.note.length;
  }
  if (r.neighbor !== null) {
    weight += r.neighbor.id % 7;
  }
  return weight;
}

function neighborId(r: Record): number {
  return r.neighbor !== null ? r.neighbor.id : -1;
}

const longLived = build(7);

let trees = 0;
for (let round = 0; round < 40; round++) {
  trees += check(build(5));
}

// A record points at the one in the next slot, whose own link is cut first: a chain through every
// record ever made would keep them all alive.
const ring: Record[] = [];
for (let i = 0; i < 24; i++) {
  ring.push(record(i, null));
}
let ringSum = 0;
for (let i = 24; i < 300; i++) {
  const slot = i % ring.length;
  const next = ring[(slot + 1) % ring.length];
  next.neighbor = null;
  ring[slot] = record(i, next);
  ringSum += weigh(ring[slot]);
  if (i % 100 === 0) {
    ringSum += check(build(4)) + ring[slot].samples.slice(40, 120).length;
  }
}

let kept = 0;
for (const r of ring) {
  kept += weigh(r);
}

console.log(check(longLived), longLived.depth, trees, ringSum, kept);
console.log(ring[5].name.slice(0, 24), ring[5].tags, ring[5].samples.slice(0, 6), ring[6].note);
console.log(ring.map(neighborId).join(" "));
