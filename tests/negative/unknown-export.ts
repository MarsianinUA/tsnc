// A module gives out only what it exports. The message stands at the specifier, so one import of
// a name that is not there is one mistake however many times it is read.
// expect: T4009 4:10
import { missing } from "./modules/values.ts";

console.log(missing);
