// `import * as` (requirements 7): the namespace holds the module's exports, constants, functions
// and types alike. A module named by two import declarations still runs once, and the modules run
// in the order the program imports them, each before the program's own top level.

import * as geometry from "./modules/geometry.ts";
import { SIDES } from "./modules/geometry.ts";
import * as counter from "./modules/counter.ts";

console.log("main loads");

const corner: geometry.Point = { x: 3, y: 4 };
const far = geometry.scale(corner, 2);

function perimeter(side: number): number {
  return side * geometry.SIDES;
}

console.log(geometry.origin, corner, far);
console.log(geometry.distance(geometry.origin, corner), geometry.distance(corner, far));
console.log(perimeter(2.5), SIDES === geometry.SIDES, counter.step(geometry.SIDES), counter.start);
