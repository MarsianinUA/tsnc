// A name bound by `import * as` stands for a module, not for an object: `values.answer` resolves
// straight to the export, and there is no value to pass anywhere on its own. Nor is it a type.
// expect: T2026 7:13
// expect: T2026 8:11
import * as values from "./modules/values.ts";

console.log(values);
let held: values = 1;
