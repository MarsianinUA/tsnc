package check_tests

import "core:strings"
import "core:testing"

import "../../src/source"

// Narrowing of a union through the flow graph bind built. What a narrowing proves is pinned by the
// programs of tests/diff/src; the two tests here hold what no program shows: what the walk costs,
// and that it reads the same in every partition.

@(test)
a_loop_body_with_many_branches_is_walked_once :: proc(t: ^testing.T) {
	// An answer worked out under a back edge is kept until the loop that cut it has been
	// evaluated, so a run of N branches in a body costs N walks and not one per path, which is
	// 2^N. Without that this program does not finish.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "function count(k: number, v: string | number): number {\n")
	strings.write_string(&b, "let t = 0;\n")
	strings.write_string(&b, "let x: string | number = v;\n")
	strings.write_string(&b, "while (t < 10) {\n")
	for i in 0 ..< 40 {
		strings.write_string(&b, "if (k === ")
		strings.write_int(&b, i)
		strings.write_string(&b, ") { t = t + ")
		strings.write_int(&b, i)
		strings.write_string(&b, "; }\n")
	}
	strings.write_string(&b, `if (typeof x === "string") { t = t + 1; }`)
	strings.write_string(&b, "\n}\nreturn t;\n}")

	c := expect_checked(t, strings.to_string(b))
	testing.expect_value(t, use_text(c, "x", 0), "number | string")
}

@(test)
a_narrowing_reads_the_same_in_every_partition :: proc(t: ^testing.T) {
	// The walk reads the frozen program and the facts of the file it is in and nothing else, so a
	// file typed on its own and the same file typed beside another give one answer. T6.2 compares
	// the whole output of `-j:1` and `-j:8`, and this is what has to hold for it.
	sources := [2]string {
		`function size(v: string | number): number { return typeof v === "string" ? v.length : v; }`,
		`function other(v: number | boolean): number { return typeof v === "boolean" ? 0 : v; }`,
	}
	together := [2]source.File_ID{MAIN, MAIN + 1}
	alone := [1]source.File_ID{MAIN}

	both := check_sources(t, sources[:], together[:])
	one := check_sources(t, sources[:], alone[:])
	testing.expectf(t, len(both.errors) == 0, "%v", both.errors)

	testing.expect_value(t, use_text(both, "v", 1), "string")
	testing.expect_value(t, use_text(both, "v", 2), "number")
	testing.expect_value(t, use_text(one, "v", 1), use_text(both, "v", 1))
	testing.expect_value(t, use_text(one, "v", 2), use_text(both, "v", 2))
}
