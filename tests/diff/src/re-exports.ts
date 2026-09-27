// Names that cross modules (requirements 7). An imported type is the type its module declared, so
// an object built here fits a function declared there; an import may rename what it takes; a
// module may pass on a name another one declares, and the name still means that declaration. And
// an imported `let` is a live binding: a write its own module makes shows through the import.

import { distance, origin } from "./modules/geometry.ts";
import type { Point } from "./modules/geometry.ts";
import { start as first, count, bump } from "./modules/counter.ts";
import { scale } from "./modules/relay.ts";
import type { Point as Relayed } from "./modules/relay.ts";

console.log("main loads");

const corner: Point = { x: 3, y: 4 };
const far: Relayed = scale(corner, 2);
const doubled = first * 2;
console.log(distance(origin, corner), far, distance(corner, far), doubled);

console.log(count);
bump();
bump();
console.log(count);
