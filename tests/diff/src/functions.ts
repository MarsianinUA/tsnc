// Function declarations: recursion, two functions that call each other, a call written above the
// declaration it names, a function that returns nothing, and a return that leaves early. Function
// declarations are hoisted, so lower declares them all before it builds any of their bodies.

console.log(greetingLength(4));

function fib(n: number): number {
  if (n < 2) {
    return n;
  }
  return fib(n - 1) + fib(n - 2);
}

function even(n: number): boolean {
  if (n === 0) {
    return true;
  }
  return odd(n - 1);
}

function odd(n: number): boolean {
  if (n === 0) {
    return false;
  }
  return even(n - 1);
}

function greetingLength(n: number): number {
  return n * 2;
}

function announce(x: number): void {
  console.log("announce", x);
}

function firstFactor(n: number): number {
  for (let i = 2; i < n; i = i + 1) {
    if (n % i === 0) {
      return i;
    }
  }
  return n;
}

function maybeAnnounce(x: number, loud: boolean): void {
  if (!loud) {
    return;
  }
  announce(x);
}

console.log(fib(0), fib(1), fib(10), fib(20));
console.log(even(0), even(7), odd(7), odd(10));
console.log(firstFactor(91), firstFactor(97));
announce(1);
maybeAnnounce(2, true);
maybeAnnounce(3, false);

// Deep recursion, so that the call sequence itself is worth something.
function depth(n: number): number {
  if (n === 0) {
    return 0;
  }
  return 1 + depth(n - 1);
}

console.log(depth(1000));
