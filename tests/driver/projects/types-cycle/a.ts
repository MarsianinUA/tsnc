import { B } from "./b";

export interface A {
	tag: string;
	next: B | null;
}

export function makeA(next: B | null): A {
	return { tag: "a", next: next };
}
