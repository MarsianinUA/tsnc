// Closures (requirements 3.5): a function value is its code and an environment. A variable a
// closure shares with the function around it, or with another closure, is one binding, so a write
// through either shows through both; one that never changes is copied. A function value keeps one
// identity, prints as Node prints it, and `typeof` names it.

function makeCounter(): () => number {
  let count = 0;
  return () => {
    count += 1;
    return count;
  };
}

const first = makeCounter();
const second = makeCounter();
console.log(first(), first(), second(), first());

function makePair(): { up: () => number; down: () => number } {
  let shared = 10;
  return { up: () => ++shared, down: () => --shared };
}

const pair = makePair();
console.log(pair.up(), pair.up(), pair.down(), pair);

function makeAdder(n: number): (x: number) => number {
  return (x: number) => x + n;
}

const add5 = makeAdder(5);
const add7 = makeAdder(7);
console.log(add5(1), add7(1), add5(add7(0)));

// A nested declaration is hoisted: it may read a const declared below it, once that has run.
function area(): number {
  function scaled(): number {
    return side * side * factor;
  }
  const side = 3;
  const factor = 2;
  return scaled();
}
console.log(area());

function fibonacci(n: number): number {
  function fib(k: number): number {
    return k < 2 ? k : fib(k - 1) + fib(k - 2);
  }
  return fib(n);
}
console.log(fibonacci(15));

function factorial(n: number): number {
  const fact = (k: number): number => (k <= 1 ? 1 : k * fact(k - 1));
  return fact(n);
}
console.log(factorial(10));

function parity(n: number, label: string): string {
  function isEven(k: number): string {
    return k === 0 ? label + " even" : isOdd(k - 1);
  }
  function isOdd(k: number): string {
    return k === 0 ? label + " odd" : isEven(k - 1);
  }
  return isEven(n);
}
console.log(parity(7, "seven"), parity(10, "ten"));

function compose(f: (x: number) => number, g: (x: number) => number): (x: number) => number {
  return (x: number) => f(g(x));
}
const both = compose(add5, (x: number) => x * 10);
console.log(both(2), compose(both, both)(1));

const ops = [(x: number) => x + 1, (x: number) => x * x, makeAdder(100)];
console.log(ops.map((op) => op(4)));

function add(a: number, b: number): number {
  return a + b;
}
const alias = add;
console.log(add, alias === add, alias(2, 3), typeof add, typeof add5);
console.log(add5, (x: number) => x, [add, add5], { run: add5 });
console.log("%o", add);
console.log("%o", (a: number, b: string) => b + a);
console.log(makeAdder(1) === makeAdder(1), first === first);
