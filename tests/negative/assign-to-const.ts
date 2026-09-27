// A `const` is written once. The rule also covers a name another module exported, which is the
// same binding read from here, whether it arrives under its own name or through a namespace, and
// whether it is assigned or bumped. The variable of a `for...of` is a `const` of its own pass.
// expect: T3009 13:1
// expect: T3009 14:9
// expect: T3009 15:9
// expect: T3009 16:1
// expect: T3009 19:2
import * as counter from "./modules/counter.ts";
import { count } from "./modules/counter.ts";

const total: number = 1;
total = 2;
counter.count = 3;
counter.count++;
count = 2;

for (const n of [1, 2]) {
	n = 3;
}
