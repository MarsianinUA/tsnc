// A module the corpus programs import. It declares one value and one type, so a program can ask a
// module for a name it does not have, use a type where a value belongs, or name the module itself.
// It is never run as a program of its own: the corpus walk takes only the files directly in
// tests/negative.

export const answer: number = 42;

export interface Point {
	x: number;
	y: number;
}
