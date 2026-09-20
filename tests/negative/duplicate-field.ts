// One name holds one field. Two declarations of it do not merge, so the second is a mistake
// rather than a value that wins.
// expect: T3015 4:23
const point = { x: 1, x: 2 };
