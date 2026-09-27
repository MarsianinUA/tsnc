// Optional chaining is not supported in v1: check for `null` or `undefined` first. A read, an
// index and a call are refused alike, and one chain is one construct.
// expect: T2016 9:18
// expect: T2016 10:21
// expect: T2016 12:19
// expect: T2016 14:17
// expect: T2016 15:18
const name: string = "tsnc";
const size = name?.length;
const trimmed = name?.trim();
const words: string[] = ["a"];
const word = words?.[0];
const f = (): number => 1;
const called = f?.();
const deep = name?.length?.toFixed;
