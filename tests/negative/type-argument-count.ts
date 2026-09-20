// A type of one's own takes no type arguments, because generics of one's own arrive in v2. Only
// the built-in `Array<T>` takes one.
// expect: T3018 7:15
interface Point {
	x: number;
}
const origin: Point<number> = { x: 0 };
