// The loop with circular-ring-a.ts is reported there, at RingA, which is declared first.
import type { RingA } from "./circular-ring-a.ts";

export type RingB = RingA | string;
