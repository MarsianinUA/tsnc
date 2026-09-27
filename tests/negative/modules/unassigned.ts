// An exported `let` with no initializer, for used-before-assigned.ts: another module may read it
// before anything assigns to it, so the declaration itself is the mistake.

export let config: number;
