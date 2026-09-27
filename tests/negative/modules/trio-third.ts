// The third module of the ring trio-first.ts opens, and the one that closes it: it calls back into
// the first as it loads.

import { tripled } from "./trio-first.ts";

export function last(): number {
	return 1;
}

export const loaded: number = tripled();
