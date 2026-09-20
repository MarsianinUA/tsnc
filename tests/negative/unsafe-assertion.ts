// `as any` is forbidden by requirements 3.8: `as` may widen a value or narrow a union, and `any`
// would switch the rules off instead. The same rule rejects the first half of `as unknown as T`.
// expect: T3019 5:23
const text: string = "tsnc";
const loose = text as any;
