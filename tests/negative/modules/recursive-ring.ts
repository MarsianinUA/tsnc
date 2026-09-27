// The other half of the loop recursive-return-type.ts closes across two modules: each function
// takes its result from the other's, so neither result can be inferred.

import { here } from "../recursive-return-type.ts";

export function there() {
	return here();
}
