// Every construct under T2021 that is a type, in the order the `Construct` enum lists them. They
// share one code, so they share one program; parse rejects each of them on sight. Two lines answer
// twice on purpose: `unique symbol` names two constructs at once, and a type parameter of one's
// own is a T2023 whatever is written on it. The last four declarations find constructs where parse
// has to look for them: a predicate after `asserts` and in a function type, an index signature on
// the line after a field with no semicolon, a getter and a numeric key in a type literal.
// expect: T2021 41:27
// expect: T2021 42:27
// expect: T2021 43:21
// expect: T2021 44:14
// expect: T2021 45:17
// expect: T2021 46:15
// expect: T2021 47:26
// expect: T2021 48:13
// expect: T2021 49:13
// expect: T2021 50:15
// expect: T2021 51:15
// expect: T2021 51:22
// expect: T2021 52:17
// expect: T2021 53:13
// expect: T2021 54:39
// expect: T2021 57:25
// expect: T2023 58:14
// expect: T2021 58:16
// expect: T2023 59:16
// expect: T2021 59:18
// expect: T2021 61:2
// expect: T2021 64:2
// expect: T2021 67:2
// expect: T2021 69:32
// expect: T2021 72:2
// expect: T2021 74:18
// expect: T2021 74:35
// expect: T2021 75:32
import * as values from "./modules/values.ts";

interface Point {
	x: number;
}
const answer: number = 1;
type Conditional = number extends string ? number : string;
type Intersection = Point & Point;
type Indexed = Point["x"];
type Tuple = [number, string];
type Template = `id-${string}`;
type Typeof = typeof answer;
type Growing = { grow(): this };
type Ctor = new () => number;
type Keys = keyof Point;
type Frozen = readonly number[];
type Unique = unique symbol;
type Inferred = infer U;
type Wide = object;
function isText(value: number): value is number {
	return true;
}
type Deep = values.Point.x;
type Bounded<T extends number> = T;
type Defaulted<T = number> = T;
interface Bag {
	[key: string]: number;
}
interface Callable {
	(x: number): number;
}
interface Constructable {
	new (): number;
}
function narrowed(x: unknown): asserts x is number {}
interface Spaced {
	x: number
	[key: string]: number;
}
type Literal = { get x(): number; 1: string };
type Guard = (x: unknown) => x is string;
