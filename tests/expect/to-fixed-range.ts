// toFixed takes 0 to 100 digits, and Node throws a RangeError for 101.
// stderr: error: toFixed() digits argument must be between 0 and 100
// exit: 1

const one = 1;
console.log(one.toFixed(101));
