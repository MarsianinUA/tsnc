// Large cells in a loop (requirements 6 and 10): past 32 KiB a cell takes a run of whole pages
// instead of a slot, and a run the collector frees is handed out again. Strings pass that size by
// doubling and arrays by pushing past 4096 numbers, each round a different size, and one round in
// three is kept to the end, so the free runs lie between runs still in use.

function wide(seed: string, width: number): string {
  let text = seed;
  while (text.length < width) {
    text = text + text;
  }
  return text;
}

function numbers(count: number, step: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < count; i++) {
    out.push((i * step) % 101);
  }
  return out;
}

function sum(values: number[]): number {
  let total = 0;
  for (const value of values) {
    total += value;
  }
  return total;
}

const texts: string[] = [];
const arrays: number[][] = [];
let checksum = 0;

for (let round = 0; round < 60; round++) {
  const text = wide("large " + round + "|", 20000 + (round % 4) * 12000);
  checksum += text.length + text.charCodeAt((round * 7919) % text.length);
  const values = numbers(4096 + round * 64, round + 1);
  checksum += sum(values) + values.length;
  if (round % 3 === 0) {
    texts.push(text);
    arrays.push(values);
  }
}

console.log(checksum, texts.length, arrays.length);
console.log(texts.map((text) => text.length).join(" "));
console.log(arrays.map(sum).join(" "));
console.log(texts[7].slice(0, 30), texts[19].slice(-12), arrays[19].slice(-5), arrays[0][4095]);
