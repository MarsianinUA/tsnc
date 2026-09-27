// A ring of modules is a mistake as soon as one of them runs code as it loads, even when the
// program itself stands outside the ring. Each ring is one message, at the import in its first
// module that points back into it, and the message lists the ring in the order the imports reach
// its modules. Requirements 7.
// expect: T4007 modules/pair-first.ts:4:24 "`tests/negative/modules/pair-first.ts`, `tests/negative/modules/pair-second.ts`"
// expect: T4007 modules/trio-first.ts:4:24 "`tests/negative/modules/trio-first.ts`, `tests/negative/modules/trio-second.ts`, `tests/negative/modules/trio-third.ts`"
import { paired } from "./modules/pair-first.ts";
import { tripled } from "./modules/trio-first.ts";

console.log(paired, tripled());
