// The built-in declarations of tsnc v1: the standard library of requirements 2.2.
//
// driver embeds this file with #load, and it becomes module number zero. It goes through the same
// parse and bind as a user file, and its names are visible in every module. lower matches each
// name here to its implementation (an intrinsic, libm, a runtime call or an inline loop), so a new
// name needs a strategy there too.
//
// Syntax: only what the v1 parser accepts. `declare const` stands for tsc's `declare var`, since
// `var` is outside the subset. There are no index signatures, so check itself knows that `s[i]` is
// a string and `a[i]` a T. There are no call signatures, so `String(x)` is a declared function and
// the value `String` has no members.
//
// Names and shapes follow tsc's lib.es5.d.ts. A type and a value may share a name, as `Math` does.
// The value `Number` is a NumberConstructor, while the type `Number` holds the methods of a
// number, as `String` does for a string and `Array<T>` for an array.
//
// A signature is narrower than tsc's where v1 cannot do more: `filter` takes a predicate that
// returns a boolean, `Number.isInteger` takes a number, `toString` has no radix, `length` and
// `process.argv` are readonly, `process.exit` takes only a number. A program that uses the wider
// form gets a compile error. `sort` answers `T[]` where tsc answers `this`, which is the same array
// here.
//
// `reduce` has two signatures, as in tsc: one without an initial value and one with it. They are
// two members with one name, and check picks the first that fits the call. Without an initial
// value, reducing an empty array is a runtime error.
//
// `Math.random` is left out: it needs generator state in the runtime, and the GC heap is the only
// state the runtime has.

interface Console {
	log(...data: any[]): void;
	error(...data: any[]): void;
}

declare const console: Console;

interface Process {
	readonly argv: string[];
	exit(code?: number): never;
}

declare const process: Process;

declare const NaN: number;
declare const Infinity: number;

interface Math {
	readonly E: number;
	readonly LN10: number;
	readonly LN2: number;
	readonly LOG2E: number;
	readonly LOG10E: number;
	readonly PI: number;
	readonly SQRT1_2: number;
	readonly SQRT2: number;
	abs(x: number): number;
	acos(x: number): number;
	acosh(x: number): number;
	asin(x: number): number;
	asinh(x: number): number;
	atan(x: number): number;
	atan2(y: number, x: number): number;
	atanh(x: number): number;
	cbrt(x: number): number;
	ceil(x: number): number;
	clz32(x: number): number;
	cos(x: number): number;
	cosh(x: number): number;
	exp(x: number): number;
	expm1(x: number): number;
	floor(x: number): number;
	fround(x: number): number;
	hypot(...values: number[]): number;
	imul(x: number, y: number): number;
	log(x: number): number;
	log10(x: number): number;
	log1p(x: number): number;
	log2(x: number): number;
	max(...values: number[]): number;
	min(...values: number[]): number;
	pow(x: number, y: number): number;
	round(x: number): number;
	sign(x: number): number;
	sin(x: number): number;
	sinh(x: number): number;
	sqrt(x: number): number;
	tan(x: number): number;
	tanh(x: number): number;
	trunc(x: number): number;
}

declare const Math: Math;

interface Number {
	toString(): string;
	toFixed(fractionDigits?: number): string;
}

interface NumberConstructor {
	isInteger(number: number): boolean;
	parseFloat(string: string): number;
}

declare const Number: NumberConstructor;

interface String {
	readonly length: number;
	charCodeAt(index: number): number;
	slice(start?: number, end?: number): string;
	indexOf(searchString: string, position?: number): number;
	includes(searchString: string, position?: number): boolean;
	split(separator: string, limit?: number): string[];
	trim(): string;
	toUpperCase(): string;
	toLowerCase(): string;
	startsWith(searchString: string, position?: number): boolean;
	endsWith(searchString: string, endPosition?: number): boolean;
}

declare function String(value?: any): string;

interface Array<T> {
	readonly length: number;
	push(...items: T[]): number;
	pop(): T | undefined;
	indexOf(searchElement: T, fromIndex?: number): number;
	includes(searchElement: T, fromIndex?: number): boolean;
	slice(start?: number, end?: number): T[];
	join(separator?: string): string;
	sort(compareFn?: (a: T, b: T) => number): T[];
	map<U>(callbackfn: (value: T, index: number, array: T[]) => U): U[];
	filter(predicate: (value: T, index: number, array: T[]) => boolean): T[];
	forEach(callbackfn: (value: T, index: number, array: T[]) => void): void;
	reduce(
		callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: T[]) => T,
	): T;
	reduce<U>(
		callbackfn: (previousValue: U, currentValue: T, currentIndex: number, array: T[]) => U,
		initialValue: U,
	): U;
}
