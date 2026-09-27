// Default exports and imports are not supported: every export has a name of its own. That covers
// every form of `export default`, a default import beside named ones or by `import type`, and
// `default` named in an import or an export list.
// expect: T2017 16:8
// expect: T2017 17:8
// expect: T2017 18:8
// expect: T2017 19:10
// expect: T2017 20:8
// expect: T2017 22:8
// expect: T2017 23:8
// expect: T2017 24:8
// expect: T2009 24:16
// expect: T2017 25:8
// expect: T2012 25:16
// expect: T2017 27:15
import values from "./modules/values.ts";
import first, { answer } from "./modules/values.ts";
import type Point from "./modules/values.ts";
import { default as fallback } from "./modules/values.ts";
export default function main(): void {
}
export default 1;
export default function () {}
export default class {}
export default async function () {}
const x = 1;
export { x as default };
