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

// A lone surrogate reaches the console as U+FFFD, as Node writes it. The two halves of a pair, each
// a string of its own, make the pair again when joined.
function joined(a: string, b: string): string {
  return a + b;
}

echo("a\uD83D");
echo("\uDE00b");
echo("\uDE00\uD83D");
echo(joined(cyrillic, "\u{1F600}"));
echo(joined("\uD83D", "\uDE00"));
