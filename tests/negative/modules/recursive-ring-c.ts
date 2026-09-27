// Its result is a string whatever ringA gives, but reading ringA to infer it closes the loop.
import { ringA } from "./recursive-ring-a.ts";

export function ringC() {
	return ringA() ? "c" : "not c";
}
