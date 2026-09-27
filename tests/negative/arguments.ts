// `arguments` is never supported: requirements 2.2, "Never". It is refused wherever it is used or
// declared: read, as a shorthand field, as a parameter, as an import.
// expect: T2005 8:20
// expect: T2005 10:12
// expect: T2005 12:13
// expect: T2005 13:11
// expect: T2005 14:16
import { answer as arguments } from "./modules/values.ts";
function count() {
    return arguments;
}
console.log(arguments);
let n = { arguments };
function named(arguments: number): void {}
