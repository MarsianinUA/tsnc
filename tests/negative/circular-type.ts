// A `type` alias is transparent, so one that stands for itself stands for nothing. An `interface`
// may name itself, because its row is reserved before its members are read. A loop of aliases is
// reported once, at the name of the alias declared first, also over two modules.
// expect: T3016 8:6
// expect: T3016 modules/circular-ring-a.ts:3:13
import type { RingA } from "./modules/circular-ring-a.ts";
import type { RingB } from "./modules/circular-ring-b.ts";
type Node = { next: Node };

const ring: RingB = "x";
