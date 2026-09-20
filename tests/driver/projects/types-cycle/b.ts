import { A } from "./a";

export interface B {
	tag: string;
	back: A | null;
}

export function makeB(back: A | null): B {
	return { tag: "b", back: back };
}
