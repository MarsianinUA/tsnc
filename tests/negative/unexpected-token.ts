// The body of an `if` or a loop is a statement, never a declaration, and an import or an export
// stands at the top level of a module only. Each is refused where it stands, and the parser goes
// on.
// expect: T1008 9:11
// expect: T1008 10:14
// expect: T1008 11:3
// expect: T1008 12:16
let flag = true;
if (flag) let x = 1;
while (flag) function f() {}
{ import "./modules/values.ts" }
function g() { export let x }
