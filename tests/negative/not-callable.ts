// Only a function or an arrow can be called. A call resolves statically, so a value with no
// signature has nothing to jump to.
// expect: T3006 5:1
const count: number = 1;
count();
