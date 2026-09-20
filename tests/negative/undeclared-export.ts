// An export list without `from` names this module's own declarations. A name nothing here
// declares has to be re-exported from the module it comes from instead.
// expect: T4003 4:10
export { missing };
