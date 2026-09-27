// The first of three modules in a ring import-cycle-modules.ts reaches. Only the third runs code
// as it loads, and that is enough to make the whole ring a mistake.

import { middle } from "./trio-second.ts";

export function tripled(): number {
	return middle() + 1;
}
