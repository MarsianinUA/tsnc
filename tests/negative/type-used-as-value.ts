// A type and a value of one name are exported separately. An imported type has nothing to pass
// anywhere: it is erased, and only a type position can name it. That holds for a name imported
// with `import type`, and for a type another module exports again. The other way round, a value
// is no type.
// expect: T4010 14:13
// expect: T4010 15:13
// expect: T4010 16:13
// expect: T4008 17:11
import { Point } from "./modules/values.ts";
import type { answer } from "./modules/values.ts";
import { answer as value } from "./modules/values.ts";
import { Point as Relayed } from "./modules/type-relay.ts";

console.log(Point);
console.log(answer);
console.log(Relayed);
let held: value = 1;
