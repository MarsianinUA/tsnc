// Reported here, at the reference to RingA, which is declared first.
import type { RingA } from "./circular-ring-a.ts";

export type RingB = RingA | string;
