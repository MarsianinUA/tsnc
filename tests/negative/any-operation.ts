// A value of type `any` stays a tagged value: tsnc reads its tag at run time, but converts it to
// nothing and looks nothing up in it. Narrow it first, with `typeof` or `as`.
// expect: T2029 5:13
const input: any = 21;
console.log(input * 2);
