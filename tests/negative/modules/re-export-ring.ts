// The other half of a ring of re-exports unknown-export.ts closes: each module passes the name on
// from the other, so it is declared nowhere, and both say so. A re-export runs nothing, so the
// ring itself is allowed.

export { round } from "../unknown-export.ts";
