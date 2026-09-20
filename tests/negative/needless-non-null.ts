// `!` checks at run time that a value is neither `null` nor `undefined`. After a type that can be
// neither there is nothing left to check, so the `!` is a mistake about the type.
// expect: T3021 5:14
const count: number = 1;
const sure = count!;
