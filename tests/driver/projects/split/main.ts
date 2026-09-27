// Built at -j:1 and -j:8 by the determinism test. `early` and late.ts are a trap for the order
// lower numbers layouts in: at -j:1 one checker meets late.ts's arrow type first, at -j:8 the
// checker of this file never reads late.ts.
import { lengthOf } from "./geometry.ts";
import type { Vec } from "./geometry.ts";
import { label } from "./labels.ts";
import { area } from "./shapes.ts";
import type { Shape } from "./shapes.ts";
import { makeCounter } from "./counter.ts";
import { each, toVec } from "./flows.ts";
import type { Offset } from "./flows.ts";
import { describe } from "./mixed.ts";
import { sum, words } from "./arrays.ts";
import { lateValue } from "./late.ts";

const early: (p: { y: number }) => number = (p: { y: number }) => p.y;

const offset: Offset = { dx: 3, dy: 4 };
const vec: Vec = toVec(offset);
const shapes: Shape[] = [
  { kind: "circle", r: 1 },
  { kind: "square", side: 2 },
];
const next = makeCounter(10);
next();

console.log(label("vec", lengthOf(vec)), each([vec, { dx: 6, dy: 8 }], lengthOf));
console.log(shapes.map(area), next(), describe(vec), describe(7), describe("seven"));
console.log(sum(words("one two three").map((w) => w.length)), lateValue);

const wide: (p: { x: number }, n: number) => number = (p: { x: number }) => p.x;
console.log(early({ y: 1 }), wide({ x: 2 }, 3));
