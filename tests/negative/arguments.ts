// `arguments` is never supported: requirements 2.2, "Never".
// expect: T2005 4:12
function count() {
    return arguments;
}
