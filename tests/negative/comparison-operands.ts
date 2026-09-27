// `<`, `<=`, `>` and `>=` order two numbers or two strings. Anything else has no order to read,
// and neither has a number against a string. Requirements 3.7 keeps the comparisons as strict as
// the equalities.
// expect: T3005 6:15
// expect: T3005 7:15
const later = true < false;
const mixed = 1 < "a";
