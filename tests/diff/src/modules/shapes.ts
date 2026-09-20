// Only a type leaves this module, so the program that names it writes `import type` and no value
// ever crosses the boundary. Node erases such an import outright and never loads the file, so this
// line must not appear in the output, and the compiler has to leave the module out of the order it
// runs initializers in.
console.log("shapes loads");

export type Size = number;
