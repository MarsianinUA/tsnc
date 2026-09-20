// `declare` belongs to the built-in lib and nowhere else: tsnc compiles the whole program from
// source, so a declaration with no value behind it names something that will never exist.
// expect: T2022 4:1
declare const version: string;
