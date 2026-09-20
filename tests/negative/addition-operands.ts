// `+` adds two numbers or joins a string with anything. Two booleans are neither, and tsnc does
// not convert them the way JavaScript does.
// expect: T3004 4:13
const sum = true + false;
