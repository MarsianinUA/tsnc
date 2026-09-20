// `Symbol` is never supported: requirements 2.2, "Never". It is a name nothing declares, and it
// answers with a rule of the subset rather than with "cannot find name".
// expect: T2025 4:16
const marker = Symbol("id");
