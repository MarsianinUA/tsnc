// A binding with neither an annotation nor an initializer has no type to infer from. Requirements
// 5: tsnc infers inside a file, it never guesses.
// expect: T3008 4:5
let pending;
