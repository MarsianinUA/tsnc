// A callback that map inlines runs where it stands, so its read of a `const` declared below it
// fails before the declaration has run, where Node throws its ReferenceError.
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-map.ts:6:48
// exit: 1

const all = [1].map((x: number): number => x + later);
const later = 1;
console.log(all);
