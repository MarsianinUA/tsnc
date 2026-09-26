// `switch`: fallthrough, a `default` that is not last, `break` binding to the switch rather than to
// the loop around it, `continue` reaching through a switch to that loop, and a `return` that leaves
// both. The cases are numbers, booleans and, last, strings, which compare by their units.

function describe(x: number): string {
  switch (x) {
    case 0:
      return "zero";
    case 1:
    case 2:
      return "small";
    default:
      return "large";
  }
}

function weigh(x: number): number {
  let total = 0;
  switch (x) {
    case 1:
      total = total + 1;
    // fallthrough
    case 2:
      total = total + 10;
      break;
    default:
      total = total + 100;
      break;
    case 3:
      total = total + 1000;
  }
  return total;
}

console.log(describe(0), describe(1), describe(2), describe(7));
console.log(weigh(1), weigh(2), weigh(3), weigh(4));

function skipEven(limit: number): number {
  let kept = 0;
  for (let i = 0; i < limit; i = i + 1) {
    switch (i % 2) {
      case 0:
        continue;
      default:
        break;
    }
    kept = kept + i;
  }
  return kept;
}

console.log(skipEven(10));

function firstOver(limit: number): number {
  for (let i = 0; i < 100; i = i + 1) {
    switch (i > limit) {
      case true:
        return i;
      default:
        break;
    }
  }
  return -1;
}

console.log(firstOver(5), firstOver(200));

function kind(word: string): string {
  switch (word) {
    case "apple":
    case "pear":
      return "fruit";
    case "":
      return "nothing";
    default:
      return "other";
  }
}

console.log(kind("apple"), kind("pear"), kind(""), kind("stone"), kind("Apple"));

// A `let` of one case read in a later one: every case shares the scope, and control that falls
// through the declaration finds the value. A jump straight to case 1 would make a closure whose
// read throws, which tests/driver pins.
function carry(x: number): number {
  let read = (): number => -1;
  switch (x) {
    case 0:
      let base = 10;
    // fallthrough
    case 1:
      read = () => base + 1;
  }
  return read();
}

console.log(carry(0), carry(5));
