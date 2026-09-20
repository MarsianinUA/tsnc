// One name holds at most one value and one type in a scope. Two declarations of it do not merge,
// and neither do two interfaces of one name.
// expect: T4001 5:7
const answer: number = 1;
const answer: number = 2;
