// `readonly` (requirements 2.2) is a promise tsc checks and then erases: a readonly field, in an
// interface, a type alias or an inline type, optional or nested, reads, passes and prints like any
// other.

interface Size {
  readonly width: number;
  readonly height: number;
}

type Item = {
  readonly name: string;
  readonly size: Size;
  readonly tags?: string[];
};

function area(size: Size): number {
  return size.width * size.height;
}

function describe(item: Item): string {
  const tags = item.tags !== undefined ? item.tags.join("+") : "none";
  return item.name + " " + area(item.size) + " " + tags;
}

function label(entry: { readonly id: number; readonly title: string }): string {
  return entry.title + "#" + entry.id;
}

function grow(size: Size, by: number): Size {
  return { width: size.width + by, height: size.height + by };
}

const box: Size = { width: 3, height: 4 };
const plain: Item = { name: "plain", size: box };
const tagged: Item = { name: "tagged", size: grow(box, 1), tags: ["red", "big"] };

console.log(box, area(box), plain, tagged);
console.log(describe(plain), describe(tagged), label({ id: 7, title: "seven" }));

// The array a readonly field holds is not readonly itself.
const list: string[] = tagged.tags !== undefined ? tagged.tags : [];
list.push("new");
console.log(tagged.tags, tagged.size.width, plain.size === box);
