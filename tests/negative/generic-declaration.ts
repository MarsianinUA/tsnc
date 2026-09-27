// Generics of one's own arrive in v2. The built-in `Array<T>` and `map<U>` stay, because the lib
// file is the one place a type parameter may be written. A function, an interface, a type alias,
// a function type and a method each declare one. The declaration is the one mistake: a use of the
// type stays quiet, and the type it names is still the one written.
// expect: T2023 11:16
// expect: T2023 14:15
// expect: T2023 17:11
// expect: T2023 18:15
// expect: T2023 20:8
// expect: T3001 24:23 "type `Box<number>` is not assignable to type `string`"
function first<T>(items: T[]): T {
	return items[0];
}
interface Box<T> {
	value: T;
}
type Pair<T> = T[];
type Apply = <U>(x: number) => U;
interface Mapper {
	apply<U>(x: number): U;
}

const held: Box<number> = { value: 1 };
const shown: string = held;
