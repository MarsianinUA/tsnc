// `Symbol` is never supported: requirements 2.2, "Never". It is a name nothing declares, and it
// answers with a rule of the subset rather than with "cannot find name", whether it is called,
// read, read through or named as a type. Any other name nothing declares is T4008.
// expect: T2025 9:16
// expect: T2025 10:13
// expect: T2025 11:18
// expect: T2025 12:12
// expect: T4008 13:15
const marker = Symbol("id");
const tag = Symbol;
const iterator = Symbol.iterator;
let typed: Symbol = 1;
const other = nowhere;
