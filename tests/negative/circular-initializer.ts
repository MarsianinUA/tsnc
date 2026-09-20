// A variable takes its type from its initializer, and this initializer reads the variable it is
// defining, so there is nothing to take it from. Writing the type after the name ends the search.
// A function in the same position is asked for a return type instead, which is T3010.
// expect: T3027 5:5
let step = step + 1;
