// args: one two три 😀 --flag=x
// process.argv (requirements 2.2) with arguments from the header line above, which the runner
// passes after the program under Node and to the build alike: Cyrillic, a character outside the
// BMP, whose length is two UTF-16 units, and a flag Node leaves to the program. The first two
// entries are the executable and the script, which differ between the two runs, so only the rest
// is printed.

const args = process.argv.slice(2);

function widths(list: string[]): number[] {
  return list.map((arg) => arg.length);
}

console.log(process.argv.length, args.length, args);
const word = args.indexOf("\u0442\u0440\u0438");
console.log(widths(args), args.join("|"), word, args.includes("--flag=x"));
for (const arg of args) {
  console.log(arg, arg.toUpperCase(), arg.startsWith("--"));
}
