// The first half of a ring import-cycle-modules.ts reaches: it reads the other half as it loads,
// which is what makes the ring a mistake.

import { second } from "./pair-second.ts";

export const paired: number = second();
