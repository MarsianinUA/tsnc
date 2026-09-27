// `declare` belongs to the built-in lib and nowhere else: tsnc compiles the whole program from
// source, so a declaration with no value behind it names something that will never exist. That
// holds for a function, an interface and a type alias as much as for a variable.
// expect: T2022 8:1 "give the declaration a value or a body"
// expect: T2022 9:1
// expect: T2022 10:1
// expect: T2022 13:1
declare const version: string;
declare function twice(x: number): number;
declare interface Point {
	x: number;
}
declare type Id = number;
