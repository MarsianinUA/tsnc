// A `const` is written once. The rule also covers a name another module exported, which is the
// same binding read from here.
// expect: T3009 5:1
const total: number = 1;
total = 2;
