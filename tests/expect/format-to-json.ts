// %j of an object with its own toJSON calls it in Node and prints "marked". tsnc calls no method
// an object holds as a field.
// stderr: error: tsnc cannot convert an object with its own toJSON to JSON
// exit: 1

const marked = { toJSON: (): string => "marked" };
console.log("%j", marked);
