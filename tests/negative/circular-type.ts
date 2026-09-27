// A `type` alias is transparent, so one that stands for itself stands for nothing. An `interface`
// may name itself, because its row is reserved before its members are read. A loop of aliases over
// two modules is reported once, at the reference to the alias declared first.
// expect: T3016 8:21
// expect: T3016 modules/circular-ring-b.ts:4:21
import type { RingA } from "./modules/circular-ring-a.ts";
import type { RingB } from "./modules/circular-ring-b.ts";
type Node = { next: Node };

const ring: RingB = "x";
