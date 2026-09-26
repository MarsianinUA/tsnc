// An `any` given to a union is checked against the union's members, as one given to a static type
// is checked against that type: 0 is neither an object nor undefined, so the program fails at the
// declaration with exit code 1 (requirements 3.8).

const input: any = 0;
const found: { n: number } | undefined = input;
console.log(found === undefined ? "none" : "some");
