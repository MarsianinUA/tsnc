// A type and a value of one name are exported separately. An imported type has nothing to pass
// anywhere: it is erased, and only a type position can name it.
// expect: T4010 6:13
import { Point } from "./modules/values.ts";

console.log(Point);
