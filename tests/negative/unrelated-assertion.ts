// `as` widens a value or narrows a union, so the two types have to be related. Two that are not
// need a conversion, not an assertion.
// expect: T3020 5:14
const count: number = 1;
const text = count as string;
