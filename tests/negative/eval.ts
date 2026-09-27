// `eval` is never supported: requirements 2.2, "Never". It is refused as a call, as a name of
// one's own and as an import. A member or a key named `eval`, `arguments` or `delete` is free.
// expect: T2007 8:10
// expect: T4009 8:10
// expect: T2007 9:1
// expect: T2007 11:2
// expect: T2007 14:6
import { eval } from "./modules/values.ts";
eval("1 + 1");
function run(): void {
	eval("1");
}
function shadow(): void {
	let eval = 1;
}
const names = { arguments: 1, eval: (): number => 2, delete: (): number => 3 };
console.log(names.arguments, names.eval(), names.delete());
