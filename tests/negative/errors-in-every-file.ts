// Every file of a program is parsed and checked, whatever the others hold: a syntax error in one
// stops no check anywhere. The diagnostics print file by file, the program first and then its
// modules in the order the imports reach them, and by position within a file.
// expect: T1007 13:9
// expect: T3001 14:22
// expect: T4008 16:28
// expect: T1007 modules/every-file-a.ts:3:26
// expect: T3001 modules/every-file-a.ts:5:23
// expect: T2001 modules/every-file-b.ts:3:1
import { a } from "./modules/every-file-a";
import { b } from "./modules/every-file-b.ts";

let c = ;
const size: number = "large";

console.log(a, b, c, size, missing);
