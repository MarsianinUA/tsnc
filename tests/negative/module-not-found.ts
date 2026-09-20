// A relative specifier names a file, and the path is relative to the module it is written in.
// `./m` and `./m.ts` both name m.ts, and neither spelling finds a file that is not there.
// expect: T4004 4:24
import { answer } from "./not-here.ts";

console.log(answer);
