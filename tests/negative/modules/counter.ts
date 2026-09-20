// A module the corpus programs import when they need a binding another module may try to write to.
// It exports a `let`, which ESM still makes read-only everywhere it is imported. It is never run as
// a program of its own: the corpus walk takes only the files directly in tests/negative.

export let count: number = 0;
