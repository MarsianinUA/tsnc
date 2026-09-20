// Modules (requirements 7): relative imports spelled with the file extension, values and functions
// crossing the boundary, the order in which the top level of each module runs, and a module that
// only types come out of, which never runs at all.

import { start, step } from "./modules/counter.ts";
import { banner, offset } from "./modules/greeting.ts";
import type { Size } from "./modules/shapes.ts";

console.log("main loads");

const size: Size = 3;

function area(width: Size, height: Size): number {
  return width * height;
}

console.log(banner, start, step(size), offset());
console.log(area(size, 4));

// A type that never becomes a value still has to resolve.
function describe(count: number): string {
  return count > 0 ? "some" : "none";
}

console.log(describe(area(size, 0)), describe(start));
