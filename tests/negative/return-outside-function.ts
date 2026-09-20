// `return` belongs to a function: the top level of a module runs on its way in and has nothing to
// return to. It completes the family of jumps that jump-outside-loop.ts pins.
// expect: T1015 4:1
return 1;
