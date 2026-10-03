// Strings built and taken apart: templates, join and split, indexOf, slice, toUpperCase, includes,
// and a `+=` that stays short, since each one copies both sides.
const ROUNDS = 10000;
const PARTS = 50;

let seed = 7;
function next(): number {
  seed = (seed * 16807) % 2147483647;
  return seed;
}

let checksum = 0;
for (let round = 0; round < ROUNDS; round++) {
  const parts: string[] = [];
  for (let i = 0; i < PARTS; i++) {
    parts.push(`item${next() % 1000}:${i}`);
  }
  const line = parts.join(",");
  const fields = line.split(",");
  let built = "";
  for (const field of fields) {
    const colon = field.indexOf(":");
    const name = field.slice(0, colon).toUpperCase();
    built += name.slice(4) + ";";
    if (field.includes("7")) {
      checksum += 1;
    }
  }
  checksum += built.length + line.indexOf("item5") + fields.length;
}
console.log(checksum);
