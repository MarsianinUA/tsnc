// A template string that substitutes nothing is a string literal written with backticks: parse
// cooks its escapes the same way, so the compiler interns it as the same text. Anything between
// ${ and } has to be joined at run time, which is milestone 5, so none appears here.

function echo(text: string): void {
  console.log(text);
}

const plain = `no substitution`;
const withQuotes = `he said "hi" and 'bye'`;
const escaped = `a\tb`;
const newline = `first\nsecond`;
const dollar = `costs $5, not $ {5}`;
const empty = ``;

// A template keeps the line breaks written inside it, and the specification normalizes them. On a
// machine that checks this file out with CRLF the cooked text still holds a bare newline, so the
// same output comes back on every system.
const spread = `over
two lines`;

echo(plain);
echo(withQuotes);
echo(escaped);
echo(newline);
echo(dollar);
echo(empty);
echo(spread);
console.log(plain, `and another`, 1);
