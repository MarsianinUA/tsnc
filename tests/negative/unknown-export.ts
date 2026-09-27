// A module gives out only what it exports. The message stands at the specifier, so one import of
// a name that is not there is one mistake however many times it is read. A declaration without
// `export` stays inside its module, a namespace has only the exports, and a re-export of a name
// the other module lacks is a mistake of its own, as is a ring of re-exports that declares the
// name nowhere.
// expect: T4009 13:10 "module `./modules/values.ts` does not export `missing`"
// expect: T4009 13:19 "write `export` in front of the declaration of `hidden` in that module, or check the spelling; a type and a value of one name are exported separately"
// expect: T4009 15:10
// expect: T4009 17:10
// expect: T4009 23:29
// expect: T4009 modules/relay-nowhere.ts:4:10 "module `./values.ts` does not export `absent`"
// expect: T4009 modules/re-export-ring.ts:5:10 "module `../unknown-export.ts` does not export `round`"
import { missing, hidden } from "./modules/values.ts";
import * as values from "./modules/values.ts";
import { absent } from "./modules/relay-nowhere.ts";

export { round } from "./modules/re-export-ring.ts";

// The reads sit in a function: a module in a ring may not run code as it loads.
function show(): void {
	console.log(missing);
	console.log(missing);
	console.log(hidden, values.missing, absent);
}
