// Every construct under T2021 that is a type, in the order the `Construct` enum lists them. They
// share one code, so they share one program; parse rejects each of them on sight, and tests/parse
// pins the wording of each on its own. Two lines answer twice on purpose: `unique symbol` names
// two constructs at once, and a type parameter of one's own is a T2023 whatever is written on it.
// expect: T2021 34:27
// expect: T2021 35:27
// expect: T2021 36:21
// expect: T2021 37:14
// expect: T2021 38:17
// expect: T2021 39:15
// expect: T2021 40:26
// expect: T2021 41:13
// expect: T2021 42:13
// expect: T2021 43:15
// expect: T2021 44:15
// expect: T2021 44:22
// expect: T2021 45:17
// expect: T2021 46:13
// expect: T2021 47:39
// expect: T2021 50:25
// expect: T2023 51:14
// expect: T2021 51:16
// expect: T2023 52:16
// expect: T2021 52:18
// expect: T2021 54:2
// expect: T2021 57:2
// expect: T2021 60:2
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
