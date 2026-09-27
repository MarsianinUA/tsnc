// A function type fits another when it takes no more parameters than the other passes, takes each
// of them as what is passed, and gives back what the other promises. A parameter the caller may
// leave out cannot turn into one the function needs, and a rest parameter is not an array. A
// callback of a lib method is held to the same signature, and so is a `return`.
// expect: T3001 12:37
// expect: T3001 13:38
// expect: T3001 14:45
// expect: T3001 15:37
// expect: T3001 18:27
// expect: T3001 19:28
// expect: T3001 22:9
const greedy: (a: number) => void = (a: number, b: number) => {};
const wrong: (a: number) => number = (a: number): string => "x";
const spread: (...xs: number[]) => number = (a: number[]): number => a.length;
const maybe: (a?: number) => void = (a: number): void => {};

const numbers = [1, 2, 3];
const texts = numbers.map((x: string) => x);
const big = numbers.filter(n => n + 1);

function count(): number {
	return "a";
}
