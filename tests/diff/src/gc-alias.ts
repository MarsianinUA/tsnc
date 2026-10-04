// What LLVM may move across a call that collects (requirements 6): the header of a fresh cell and
// the length of an array must reach memory before it, since the collector reads them to find the
// references a cell holds. Every pass allocates between those stores and the reads after them,
// which GC stress turns into a collection each time.

interface Link {
  name: string;
  next: Link | null;
}

interface Circle {
  kind: "circle";
  r: number;
}

interface Square {
  kind: "square";
  side: number;
}

type Shape = Circle | Square;

const text = "αβγ-abc-ÄÖÜ";
const parts: string[] = [];
const shapes: Shape[] = [];
let head: Link | null = null;

for (let i = 0; i < 300; i++) {
  const unit = text[i % text.length];
  parts.push(unit.toLowerCase());
  head = { name: unit + i, next: head };
  const shape: Shape = i % 2 === 0 ? { kind: "circle", r: i } : { kind: "square", side: i };
  shapes.push(shape);
}

let names = 0;
for (let link = head; link !== null; link = link.next) {
  names += link.name.length;
}
let sides = 0;
for (const shape of shapes) {
  sides += shape.kind === "circle" ? shape.r : 2 * shape.side;
}
console.log(parts.join(""));
console.log(names, sides, head === null ? "" : head.name);
