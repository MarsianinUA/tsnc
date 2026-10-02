// process.exit takes an integer code, and Node throws a RangeError for 1.5.
// stdout: before
// stderr: error: process.exit code is not an integer
// exit: 1

console.log("before");
process.exit(1.5);
