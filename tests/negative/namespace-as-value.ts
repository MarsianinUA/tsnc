// A name bound by `import * as` stands for a module, not for an object: `values.answer` resolves
// straight to the export, and there is no value to pass anywhere on its own.
// expect: T2026 6:13
import * as values from "./modules/values.ts";

console.log(values);
