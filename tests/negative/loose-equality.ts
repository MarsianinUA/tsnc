// `==` is allowed only where it already means `===`, which is both sides having one type.
// Requirements 3.7.
// expect: T3002 5:14
const text: string = "1";
const same = 1 == text;
