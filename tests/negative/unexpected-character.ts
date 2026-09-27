// A character that starts no token is reported and skipped, and the text goes on after it as if it
// were not there. A backslash escape in a name is such a character: the subset spells names as
// they are.
// expect: T1001 7:13 "`#`"
// expect: T1001 8:13 "`¤`"
// expect: T1001 9:7 "`\`"
const a = 1 #;
const b = 2 ¤;
const \u0061lias = 3;
