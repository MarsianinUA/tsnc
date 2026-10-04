// A narrow object where a wider object type is expected (requirements 3.3): the value that flows is
// the same object, not a copy, so a write through the wide type shows through the narrow one and
// `===` holds. The write here keeps to the narrow type; one that did not would fail the read through
// the narrow type at run time (requirements 3.8), which tests/expect/field-other-kind.ts runs.

interface Size {
  width: number;
}

interface Measure {
  width: number | string;
}

interface Inner {
  v: number;
}

interface Outer {
  inner: Inner;
}

interface OuterWide {
  inner: { v: number | boolean };
}

function show(m: Measure): void {
  console.log("measure", m.width, m);
}

function scale(o: Outer): number {
  return o.inner.v * 2;
}

const box: Size = { width: 10 };
show(box);
const same: Measure = box;
console.log(box === same);
same.width = 25;
console.log(box.width + 1, box);

const outer: Outer = { inner: { v: 4 } };
const loose: OuterWide = outer;
loose.inner.v = 6;
console.log(scale(outer), loose, loose.inner === outer.inner);

const list: Measure[] = [box, { width: "auto" }];
console.log(list, list[0] === box);

// A write through the narrow type goes into the slot the wide type shares, and an `as` back to
// the narrow type answers the same object.
function write(s: Size): void {
  s.width = 2;
}
write(box);
const back = same as Size;
console.log(box, same.width, back === box, back.width + 1);

interface Item {
  v: number;
}

interface Holder {
  item: Item;
}

interface Loose {
  item: Item | null;
}

function loosen(h: Holder): Loose {
  return h;
}

// Holder widens into Loose, so a read of item through Holder checks what the shared slot holds.
function read(h: Holder): number {
  return h.item.v;
}

const holder: Holder = { item: { v: 8 } };
const loosened = loosen(holder);
console.log(read(holder), loosened.item === holder.item, loosened);

// An array where an array of a wider element type is expected is the same array too (requirements
// 3.6): a push through either type shows through the other. The writes through the wide type keep
// to the narrow one; a read through the narrow type of what one did not keep to fails at run time,
// which tests/expect/element-other-kind.ts runs.
interface Disc {
  kind: "disc";
  r: number;
}

interface Square {
  kind: "square";
  side: number;
}

type Shape = Disc | Square;

function addAll(into: Shape[], from: Shape[]): void {
  for (const s of from) {
    into.push(s);
  }
}

function area(s: Shape): number {
  return s.kind === "disc" ? 3 * s.r * s.r : s.side * s.side;
}

const discs: Disc[] = [{ kind: "disc", r: 3 }];
const shapes: Shape[] = discs;
shapes.push({ kind: "disc", r: 1 });
discs.push({ kind: "disc", r: 2 });
console.log(discs === shapes, shapes.length, discs[1].r, shapes[2]);

discs[0] = { kind: "disc", r: 4 };
discs.sort((a, b) => a.r - b.r);
let radii = 0;
for (const d of discs) {
  radii += d.r;
}
const widest = discs.reduce((a, b) => (a.r > b.r ? a : b));
console.log(
  discs.map((d) => d.r),
  discs.filter((d) => d.r > 1).length,
  radii,
  discs.reduce((sum, d) => sum + d.r, 0),
  widest,
);

const all: Shape[] = [{ kind: "square", side: 2 }];
addAll(all, discs);
const grid: Disc[][] = [discs];
const rows: Shape[][] = grid;
const narrowed = shapes as Disc[];
console.log(all.map(area), all, rows[0] === discs, narrowed === discs);

// A union of objects, with null too, is one pointer; the header of its cell tells the layout.
function pick(i: number): Shape | null {
  return i < all.length ? all[i] : null;
}
const picked = [pick(0), pick(9)];
const second = pick(1);
if (second !== null) {
  console.log(second.kind, second === discs[0], second === all[0], area(second));
}
console.log(picked, picked[0] === all[0], picked[1] === null, typeof picked[1], (all[0] as Square).side);

const items: Item[] = [{ v: 1 }];
const holes: (Item | null)[] = items;
holes.push({ v: 2 });
console.log(items[1].v + 1, holes);

// split and process.argv make a string[], which here flows into a wider array type.
const words = "b,a".split(",");
const mixed: (string | number)[] = words;
mixed.push(3);
words.push("c");
console.log(words, mixed.length, words[1].toUpperCase(), words.join("-"));
console.log(process.argv.slice(2), typeof process.argv[0]);

// A write of a field that holds an object reaches the object types that flow into the field's type:
// the cell written here is read through the narrower type of the field afterwards.
interface Cell2 {
  w: number;
}

interface Box2 {
  cell: Cell2;
}

interface BoxWide {
  cell: { w: number | boolean };
}

function cellWidth(b: Box2): number {
  return b.cell.w * 2;
}

const box2: Box2 = { cell: { w: 4 } };
const wideBox: BoxWide = box2;
wideBox.cell = { w: 7 };
console.log(cellWidth(box2), wideBox.cell === box2.cell);

// pop and sort change the array they are called on, so a wide type they go through shares the
// layout of what flows into it, as push does.
interface Tile {
  t: number;
}

const tiles: Tile[] = [{ t: 3 }, { t: 1 }, { t: 2 }];
const looseTiles: (Tile | null)[] = tiles;
looseTiles.sort((a, b) => (a === null ? 0 : a.t) - (b === null ? 0 : b.t));
const last = looseTiles.pop();
console.log(tiles, last, tiles.length, tiles[0].t);

// An `as` to the narrower type reads a cell that may have been made as the wider one, so it joins
// the layouts as a write through the wider type does.
interface Plain {
  x: number;
  y: number;
}

interface Mixed {
  x: number | string;
  y: number;
}

const mixedPoint: Mixed = { x: 1, y: 2 };
const someNumbers: (number | boolean)[] = [1, 2];
console.log((mixedPoint as Plain).x + 1, (someNumbers as number[]).length);
