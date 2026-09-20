// The short-circuit operators and the ternary. `&&` and `||` answer one of their operands rather
// than a boolean, and they only evaluate the right one when they have to — which a counter makes
// visible. Truthiness is the other half: both zeros and NaN are false, every other number is true.

let calls = 0;

function count(answer: boolean): boolean {
  calls = calls + 1;
  return answer;
}

function truthy(x: number): boolean {
  return x ? true : false;
}

function pick(flag: boolean, yes: number, no: number): number {
  return flag ? yes : no;
}

console.log(count(false) && count(true), calls);
console.log(count(true) || count(false), calls);
console.log(count(true) && count(false), calls);
console.log(count(false) || count(true), calls);

console.log(truthy(1), truthy(0), truthy(-0), truthy(NaN), truthy(-1), truthy(Infinity));

console.log(pick(true, 1, 2), pick(false, 1, 2));
console.log(pick(truthy(0), 1, pick(truthy(2), 3, 4)));

console.log(!true, !false, !!true);

// A nested chain, so that the phi that joins the branches has more than two edges to merge.
function classify(x: number): number {
  return x < 0 ? -1 : x > 0 ? 1 : 0;
}

console.log(classify(-5), classify(0), classify(5));
