// The other half of the trap in main.ts: no other file reads `widened`.
export const lateValue: number = 4;

const widened: (p: { y: number }, n: number) => number = (p: { y: number }) => p.y * 2;
console.log(widened({ y: 5 }, 6));
