// `namespace` is never supported: requirements 2.2, "Never". Nor is `module`, a dotted name, an
// ambient `declare` of either, or `declare global`. `namespace` counts only with its name on the
// same line: below the last one it is a name of its own, read as a statement.
// expect: T2003 10:1
// expect: T2003 12:1
// expect: T2003 14:9
// expect: T2003 16:9
// expect: T2003 18:9
// expect: T2003 21:2
namespace shapes {
}
module outer.inner {
}
declare namespace ambient {
}
declare module "m" {
}
declare global {
}
function g(): void {
	namespace local {
	}
}
const namespace = 1;
const N = 2;
namespace
N
{
}
