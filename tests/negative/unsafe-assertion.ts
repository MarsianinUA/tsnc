// `as any` is forbidden by requirements 3.8: `as` may widen a value or narrow a union, and `any`
// would switch the rules off instead. The same rule rejects the first half of `as unknown as T`,
// and the second half then stays quiet, so the pair is one mistake.
// expect: T3019 8:23 "`as any`"
// expect: T3019 9:18
// expect: T3019 10:20
const text: string = "tsnc";
const loose = text as any;
const bad = 1 as unknown as string;
const alone = 1 as unknown;
