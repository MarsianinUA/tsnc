// A name has to be declared before this point or imported from the module it lives in. tsnc has
// no globals beyond the declarations of its built-in lib.
// expect: T4008 4:15
const total = missing + 1;
