// A function type fits another when it takes no more parameters than the other passes, takes each
// of them as what is passed, and gives back what the other promises. A parameter the caller may
// leave out cannot turn into one the function needs, and a rest parameter is not an array. A
// callback of a lib method is held to the same signature, and so is a `return`. A signature prints
// with the parameter names it was written with, even after another spelling of it came first.
// expect: T3001 14:37
// expect: T3001 15:38
// expect: T3001 16:45
// expect: T3001 17:37
// expect: T3001 20:27
// expect: T3001 21:28
// expect: T3001 24:9
// expect: T3001 28:44 "not assignable to type `(total: number) => string`"
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

const counted: (count: number) => string = (n: number): string => "x";
const wrongly: (total: number) => string = (n: number): number => n;
