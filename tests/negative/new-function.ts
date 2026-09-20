// `new Function` is never supported: requirements 2.2, "Never".
// expect: T2008 3:1
new Function("a", "return a");
