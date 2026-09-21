// A side that never comes back: process.exit, or a function declared to return never. It is no edge
// of the join after it, so the value of the whole expression is what the other side brought. And a
// ternary or a short circuit written as a statement joins no value at all, so its two sides need
// not agree on a type. The program takes none of its never sides: it prints and runs off the
// bottom, for the reason exit.ts gives.

function die(code: number): never {
  process.exit(code);
}

function positive(n: number): number {
  return n > 0 ? n : process.exit(70);
}

function doubled(n: number): number {
  const x: number = n > 0 ? n * 2 : die(72);
  return x + 1;
}

function checked(n: number): number {
  n > 0 || process.exit(71);
  return n;
}

let calls = 0;

function touch(): void {
  calls = calls + 1;
}

function either(c: boolean): void {
  c ? touch() : touch();
}

function assigned(c: boolean): number {
  let x = 1;
  c && (x = 5);
  return x;
}

function announce(debug: boolean): void {
  debug && console.log("debug");
}

function guard(ok: boolean): boolean {
  ok || process.exit(73);
  return ok;
}

console.log(positive(2), doubled(2), checked(3));
either(true);
either(false);
console.log(calls);
console.log(assigned(true), assigned(false));
announce(true);
announce(false);
console.log(guard(true));
