// A narrow object where a wider object type is expected (requirements 3.3): the value that flows is
// the same object, not a copy, so a write through the wide type shows through the narrow one and
// `===` holds. The write here keeps to the narrow type; one that did not would fail the read through
// the narrow type at run time (requirements 3.8), which is no program for this corpus.

interface Size {
  width: number;
}

interface Measure {
  width: number | string;
}

interface Inner {
  v: number;
}

interface Outer {
  inner: Inner;
}

interface OuterWide {
  inner: { v: number | boolean };
}

function show(m: Measure): void {
  console.log("measure", m.width, m);
}

function scale(o: Outer): number {
  return o.inner.v * 2;
}

const box: Size = { width: 10 };
show(box);
const same: Measure = box;
console.log(box === same);
same.width = 25;
console.log(box.width + 1, box);

const outer: Outer = { inner: { v: 4 } };
const loose: OuterWide = outer;
loose.inner.v = 6;
console.log(scale(outer), loose, loose.inner === outer.inner);

const list: Measure[] = [box, { width: "auto" }];
console.log(list, list[0] === box);
