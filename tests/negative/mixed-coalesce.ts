// `??` next to `&&` or `||` needs parentheses, on either side, as in TypeScript: the order they
// would be read in is not the one a reader expects. With the parentheses written, either order is
// fine.
// expect: T1009 10:14
// expect: T1009 11:19
// expect: T1009 12:19
let a: number | undefined = 1;
let b = 2;
let c = 3;
const r1 = a ?? b || c;
const r2 = a || b ?? c;
const r3 = a && b ?? c;
const r4 = (a || b) ?? c;
const r5 = a ?? (b || c);
