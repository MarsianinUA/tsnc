// The second of the three modules in the ring trio-first.ts opens. It runs nothing as it loads.

import { last } from "./trio-third.ts";

export function middle(): number {
	return last() + 1;
}
