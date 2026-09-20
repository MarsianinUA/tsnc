// A comparison of two types with no value in common never holds, so it is a mistake rather than a
// test. The same question is what narrows a union member by member.
// expect: T3022 5:14
const count: number = 1;
const same = count === "one";
