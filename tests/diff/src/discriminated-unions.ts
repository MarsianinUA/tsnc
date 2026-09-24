// Discriminated unions (requirements 2.2): a union of object types told apart by a field with a
// literal type. Reading the field is a dispatch over the layouts of the members, and a test of it
// narrows the value, which is then unboxed with a check of its tag and its layout (requirements 3.4,
// 3.8). The three shapes have three layouts; the Result members, two.

interface Circle {
  kind: "circle";
  radius: number;
}

interface Square {
  kind: "square";
  side: number;
}

interface Rect {
  kind: "rect";
  width: number;
  height: number;
}

type Shape = Circle | Square | Rect;

function area(s: Shape): number {
  switch (s.kind) {
    case "circle":
      return Math.PI * s.radius * s.radius;
    case "square":
      return s.side * s.side;
    case "rect":
      return s.width * s.height;
    default: {
      // Every member has a case, so s is `never` here, which is how TypeScript checks the switch
      // covers them all.
      const unreachable: never = s;
      return unreachable;
    }
  }
}

function describe(s: Shape): string {
  if (s.kind === "circle") {
    return "circle of radius " + s.radius;
  }
  if (s.kind === "square") {
    return `square of side ${s.side}`;
  }
  return "rect " + s.width + "x" + s.height;
}

function grow(s: Shape): void {
  if (s.kind === "rect") {
    s.width += 1;
  } else if (s.kind === "square") {
    s.side *= 2;
  }
}

const shapes: Shape[] = [
  { kind: "circle", radius: 1 },
  { kind: "square", side: 2 },
  { kind: "rect", width: 3, height: 4 },
];

for (const s of shapes) {
  console.log(describe(s), area(s).toFixed(3));
}
const areas = shapes.map(area);
console.log(areas.map((a) => a.toFixed(2)).join(" "));
console.log(shapes.reduce((total, s) => total + (s.kind === "circle" ? 1 : 0), 0), "circle");
console.log(shapes.filter((s) => s.kind !== "circle").length, "with corners");
shapes.forEach(grow);
console.log(shapes);
console.log(shapes.map((s) => s.kind).join(","));

type Result = { ok: true; value: number } | { ok: false; error: string };

function divide(a: number, b: number): Result {
  if (b === 0) {
    return { ok: false, error: "division by zero" };
  }
  return { ok: true, value: a / b };
}

function show(r: Result): string {
  if (r.ok === true) {
    return "value " + r.value;
  }
  return "error " + r.error;
}

function unwrap(r: Result, fallback: number): number {
  return r.ok === false ? fallback : r.value;
}

console.log(show(divide(1, 2)), show(divide(1, 0)));
console.log(unwrap(divide(9, 3), -1), unwrap(divide(9, 0), -1));
console.log(divide(3, 4), divide(3, 0));
