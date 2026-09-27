// Part of the loop recursive-return-type.ts enters at ringB. Declared first, so reported here.
import { ringB } from "./recursive-ring-b.ts";

export function ringA() {
	return ringB();
}
