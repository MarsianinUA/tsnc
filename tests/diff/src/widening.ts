// A narrow object where a wider object type is expected (requirements 3.3): the value that flows is
// the same object, not a copy, so a write through the wide type shows through the narrow one and
// `===` holds. The write here keeps to the narrow type; one that did not would fail the read through
// the narrow type at run time (requirements 3.8), which tests/expect/field-other-kind.ts runs.

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

// A write through the narrow type goes into the slot the wide type shares, and an `as` back to
// the narrow type answers the same object.
function write(s: Size): void {
  s.width = 2;
}
write(box);
const back = same as Size;
console.log(box, same.width, back === box, back.width + 1);

interface Item {
  v: number;
}

interface Holder {
  item: Item;
}

interface Loose {
  item: Item | null;
}

function loosen(h: Holder): Loose {
  return h;
}

// Holder widens into Loose, so a read of item through Holder checks what the shared slot holds.
function read(h: Holder): number {
  return h.item.v;
}

const holder: Holder = { item: { v: 8 } };
const loosened = loosen(holder);
console.log(read(holder), loosened.item === holder.item, loosened);
