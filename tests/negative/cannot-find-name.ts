// A name has to be declared before this point or imported from the module it lives in. tsnc has
// no globals beyond the declarations of its built-in lib. A type is looked up the same way.
// expect: T4008 5:15
// expect: T4008 6:10
const total = missing + 1;
const p: Missing = 1;
