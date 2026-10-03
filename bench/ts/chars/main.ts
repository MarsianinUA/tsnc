// A tokenizer-style scan: every unit of a long ASCII text read as a one-character string, by index
// and by for...of. The text is built by push and join, which copy each word once.
const WORDS = 200000;
const ROUNDS = 10;
const LETTERS = "abcdefghijklmnopqrstuvwxyz";

let seed = 42;
function next(): number {
  seed = (seed * 16807) % 2147483647;
  return seed;
}

const words: string[] = [];
for (let i = 0; i < WORDS; i++) {
  let word = "";
  const length = 1 + (next() % 9);
  for (let k = 0; k < length; k++) {
    word += LETTERS[next() % 26];
  }
  words.push(word);
}
const text = words.join(" ");

let checksum = 0;
for (let round = 0; round < ROUNDS; round++) {
  let count = 1;
  let longest = 0;
  let run = 0;
  let vowels = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === " ") {
      count++;
      if (run > longest) {
        longest = run;
      }
      run = 0;
    } else {
      run++;
      if (c === "a" || c === "e" || c === "i" || c === "o" || c === "u") {
        vowels++;
      }
    }
  }
  let es = 0;
  for (const c of text) {
    if (c === "e") {
      es++;
    }
  }
  checksum += count + longest + vowels + es + round;
}
console.log(text.length, checksum);
