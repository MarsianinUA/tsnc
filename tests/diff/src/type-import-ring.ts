// A type-only import orders nothing (requirements 7): the ring between type-ring-a and type-ring-b
// closes only through `import type`, so there is no ring to run in the wrong order and nothing to
// report, and type-ring-b never runs.
import { describe, first } from "./modules/type-ring-a.ts";

console.log("main loads", first, describe({ name: "later" }));
