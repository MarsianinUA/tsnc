import { b } from "./recursive-entry-b.ts";
import { c } from "./recursive-entry-c.ts";

export function a(n: number) {
	return n > 0 ? b(n - 1) + c(n - 1) : 0;
}
