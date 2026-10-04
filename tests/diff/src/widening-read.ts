// A wide type the program only reads through (requirements 3.3, 3.6): what flows into it keeps its
// own layout, so a number[] stays an array of numbers, and a read through the wide type tests which
// layout the cell has. Nothing here writes through a wide type, which would join the layouts again
// (widening.ts); a key is one for the whole program, so such a write anywhere would hide these.

function spell(items: (number | string)[]): string {
  let out = "";
  for (const item of items) {
    out += typeof item === "number" ? `n${item}` : item;
  }
  items.forEach((item, i) => {
    out += i === 0 ? `|${item}` : "";
  });
  return out;
}

function summary(items: (number | string)[]): (number | string)[] {
  const firsts = items.slice(0, 2);
  return [
    items.length,
    items[0],
    items.indexOf(2),
    items.includes("x") ? 1 : 0,
    items.map((x) => typeof x).join(),
    items.filter((x) => typeof x === "number").length,
    items.reduce((a, x) => a + String(x), ">"),
    firsts.length,
    items.join("+"),
  ];
}

const counts: number[] = [1, 2, 3];
const labels: (number | string)[] = ["x", 4];
const seen: (number | string)[] = counts;
console.log(spell(counts), spell(labels), summary(counts), summary(labels));
counts.push(4);
console.log(seen === counts, seen, counts[3] + 1, seen.length);

interface Point2 {
  x: number;
  y: number;
}

interface Loose2 {
  x: number | string;
  y: number;
}

function describePoint(p: Loose2): string {
  return `${p.x}/${p.y}`;
}

const pt: Point2 = { x: 1, y: 2 };
const free: Loose2 = { x: "a", y: 3 };
const viewed: Loose2 = pt;
console.log(describePoint(pt), describePoint(free), viewed === pt, viewed, viewed.y + 1);
pt.x = 5;
console.log(describePoint(viewed), [viewed, free]);

// A reference slot of what flows in holds a string in one type and an object in another of one
// shape, so the wide read boxes what that type holds. Where both reach one wide type, which the
// header cannot tell apart, they share its layout instead.
interface Spot {
  at: string;
}

interface Placed {
  at: Point2;
}

function where(p: { at: string | number }): string | number {
  return p.at;
}

function anywhere(p: { at: string | Point2 | number }): string {
  const at = p.at;
  return typeof at === "object" ? `${at.x},${at.y}` : `${at}`;
}

function walk(p: Placed): number {
  return p.at.x + p.at.y;
}

interface Badge {
  tag: string;
}

function tagOf(b: { tag: string | number }): string | number {
  return b.tag;
}

const spot: Spot = { at: "home" };
const placed: Placed = { at: { x: 8, y: 9 } };
console.log(where(spot), where({ at: 3 }), walk(placed));
console.log(tagOf({ tag: "b" } as Badge), tagOf({ tag: 2 }));
console.log(anywhere(spot), anywhere(placed), anywhere({ at: 4 }));

// A chain of flows: what reaches the middle type reaches the end one too.
interface Leaf {
  leaf: number;
}

function chainEnd(c: { c: Leaf | null | string }): string {
  const v = c.c;
  return v === null ? "none" : typeof v === "string" ? v : `${v.leaf}`;
}

function chainMid(c: { c: Leaf | null }): string {
  return chainEnd(c);
}

const holder: { c: Leaf } = { c: { leaf: 3 } };
console.log(chainMid(holder), chainEnd({ c: "s" }), chainMid({ c: null }), chainEnd(holder));

// A wide field of an object only read through, and an array of a wide object type.
interface Deep {
  inner: { w: number };
}

function deepValue(d: { inner: { w: number | boolean } }): number | boolean {
  return d.inner.w;
}

const deep: Deep = { inner: { w: 7 } };
const loosePoints: Loose2[] = [pt, free];
const narrowPoints: Point2[] = [pt];
const widePoints: Loose2[] = narrowPoints;
console.log(deepValue(deep), deepValue({ inner: { w: true } }), loosePoints[0].x, widePoints[0].y);
