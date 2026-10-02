// Two alias loops over three modules share CircleA, so they are one loop, reported once at the
// alias declared first, whichever alias a checker reads first.
// expect: T3016 modules/circular-entry-a.ts:4:13
import type { CircleA } from "./modules/circular-entry-a.ts";
import type { CircleC } from "./modules/circular-entry-c.ts";

const a: CircleA = 1;
const c: CircleC = "c";
console.log(a, c);
