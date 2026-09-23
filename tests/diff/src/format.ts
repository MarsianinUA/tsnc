// Format strings (requirements 3.9): a string first argument of console.log is read the way Node's
// util.format reads it, and every specifier converts its argument the way Node does. Only
// primitives appear here: a program cannot build an array or an object yet, and the runtime unit
// tests hold those.

function show(value: string | number | boolean | null | undefined): void {
  console.log("%s|%d|%i|%f|%j|%o|%O", value, value, value, value, value, value, value);
}

// Every specifier once, then the ones that take no argument or have none left.
console.log("%s|%d|%i|%f|%j|%o|%O|%c|%%", "a", "42", "12.9", "1.5e3", "q", "s", 7, "css");
console.log("%s %s", "only");
console.log("%x %s", "y");
console.log("trailing %", 1);
console.log("%%", 1);
console.log("%", 1);
console.log(1, "%s", 2);
console.error("%s=%d", "n", 42);

// Each specifier over the kinds of value a primitive can be.
show("text");
show("  0x1F  ");
show(" 3.25xyz");
show("1e21");
show("");
show(-0);
show(0.1);
show(1e21);
show(NaN);
show(-Infinity);
show(true);
show(false);
show(null);
show(undefined);

// %o and %O of a string quote it, escape what needs it, and pick the quote that saves an escape.
console.log("%O", "tab\there, a \"double\" quote");
console.log("%O", "it's");
console.log("%O", "it's \"both\"");
console.log("%O", "it's \"all\" `three`");
console.log("%o", "\u0000\u001f\u007f\u0085\\");
console.log("%O", "\ud800 lone and \ud83d\ude00 paired");

// A string longer than sixteen units that does not fit on the line breaks after each line end.
console.log("%O", "short line\nanother line that makes the string too long for one line of eighty");
console.log("%o", "no line end but still a long string that is well past eighty columns wide");

// %j of a string is JSON: control characters as \u00XX, a lone surrogate escaped.
console.log("%j", "q\"\\\b\f\n\r\t\u0001\ud800");
