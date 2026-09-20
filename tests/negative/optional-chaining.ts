// Optional chaining is not supported in v1: check for `null` or `undefined` first.
// expect: T2016 4:18
const name: string = "tsnc";
const size = name?.length;
