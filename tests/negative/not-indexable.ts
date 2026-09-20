// `x[i]` reads an element of an array or a code unit of a string. Nothing else is indexed, since
// index signatures arrive in v2.
// expect: T3013 5:15
const ready: boolean = true;
const first = ready[0];
