package check_tests

import "core:testing"

import "../../src/source"

// Names that come from another module. A test writes several sources; check_sources names them
// m1.ts, m2.ts and so on, and an import names one of those, so the module graph is the real one.

@(test)
one_partition_and_any_split_give_the_same_answer :: proc(t: ^testing.T) {
	// The invariant of Check_Result that T6.2 compares byte for byte. The function in m2 has a result
	// inferred from a narrowed value, which needs the fact tables of that file: a checker that only
	// reads m2 has to reach the same answer as the one that types it.
	sources := [2]string {
		lines(
			`import { widen } from "./m2.ts";`, //
			`const text = widen("a");`,
		),
		lines(
			`export function widen(v: string | number) {`, //
			`	if (typeof v === "string") {`,
			`		return v;`,
			`	}`,
			`	return "n";`,
			`}`,
		),
	}
	whole := [2]source.File_ID{MAIN, MAIN + 1}
	first := [1]source.File_ID{MAIN}
	second := [1]source.File_ID{MAIN + 1}

	together := check_sources(t, sources[:], whole[:])
	apart := check_sources(t, sources[:], first[:])
	owner := check_sources(t, sources[:], second[:])

	testing.expectf(t, len(together.file_errors) == 0, "%v", together.file_errors)
	testing.expectf(t, len(apart.file_errors) == 0, "%v", apart.file_errors)
	testing.expectf(t, len(owner.file_errors) == 0, "%v", owner.file_errors)

	testing.expect_value(t, declared_text(together, "text"), "string")
	testing.expect_value(t, declared_text(apart, "text"), "string")
	// The checker that owns m2 works the same result out from the file itself. The union prints in
	// canonical order, which is structural and the same in every checker.
	testing.expect_value(
		t,
		declared_text(owner, "widen", MAIN + 1),
		"(v: number | string) => string",
	)
	testing.expect_value(
		t,
		declared_text(together, "widen", MAIN + 1),
		"(v: number | string) => string",
	)
}
