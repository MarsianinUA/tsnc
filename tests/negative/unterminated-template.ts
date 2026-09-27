// A template literal runs across lines to its closing backtick, so one left open takes the rest of
// the file with it. The message stands where the open part starts.
// expect: T1003 5:22
const name = "x";
const text = `a${name}b
console.log(text);
