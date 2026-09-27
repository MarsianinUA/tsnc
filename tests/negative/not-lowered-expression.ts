// An expression lower gives up on without a construct to name, here the `!` of a call that never
// returns. The build still refuses it, at the expression, rather than emitting nothing for it.
// It stands alone: the build names it only when nothing else in the program was refused.
// expect: T2027 5:11 "this expression"
const b = !process.exit(3);
