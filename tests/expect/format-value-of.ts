// %d of an object with its own valueOf calls it in Node and prints 3. tsnc calls no method an
// object holds as a field.
// stderr: error: tsnc cannot convert an object with its own valueOf or toString to a number
// exit: 1

const three = { valueOf: (): number => 3 };
console.log("%d", three);
