// A million cells of 24 bytes, some 23 MB, so the collector runs while generated code takes most
// of them off the free lists itself.
let last = { a: 0, b: 0 };
for (let i = 1; i <= 1000000; i++) {
  last = { a: i, b: 1 };
}
console.log(last.a + last.b);
