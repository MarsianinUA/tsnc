// A `const` is written once. The rule also covers a name another module exported, which is the
// same binding read from here, whether it arrives under its own name or through a namespace.
// expect: T3009 8:1
// expect: T3009 9:9
import * as counter from "./modules/counter.ts";

const total: number = 1;
total = 2;
counter.count = 3;
