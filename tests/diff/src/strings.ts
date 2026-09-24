// String literals (requirements 3.2): stored in a binding, handed to a function, printed. The
// runtime keeps a string as UTF-16 and re-encodes it to UTF-8 at the console, so the alphabets that
// prove the path are the ones outside ASCII: Cyrillic in the basic plane, an emoji built from a
// surrogate pair, and an escape that names a code point rather than typing it.
//
// Everything else a string can do (joining, comparing, length, the methods) is string-methods.ts.

function echo(text: string): void {
  console.log(text);
}

function label(name: string, value: number): void {
  console.log(name, value);
}

const ascii = "plain text";
const cyrillic = "Привет, мир";
const emoji = "тест 🎉 готов";
const escaped = "\u00e9\u0301 \u{1F600}";
const quoted = "he said \"hi\"";
const tabbed = "a\tb\\c";

echo(ascii);
echo(cyrillic);
echo(emoji);
echo(escaped);
echo(quoted);
echo(tabbed);
echo("");
label(cyrillic, 1);
console.log(ascii, cyrillic, emoji);
