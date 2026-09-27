// An export list without `from` names this module's own declarations. A name nothing here
// declares, a global of the lib among them, has to be re-exported from the module it comes from
// instead.
// expect: T4003 6:10
// expect: T4003 7:10
export { missing };
export { console };
