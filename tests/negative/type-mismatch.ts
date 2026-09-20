// The general assignability rule: a value goes only where its type fits. Requirements 5.
// The literal type of `"many"` is what the message names, since that is what the value is.
// expect: T3001 4:23
const count: number = "many";
