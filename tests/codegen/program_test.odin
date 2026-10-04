package codegen_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ir"

/*
Whole programs through codegen, from a TypeScript source or from IR built by hand, read back as
LLVM text.
*/

// tsnc_main leaves the object file, since the runtime calls it, and it calls the init of every
// module in the order the program graph put them.
@(test)
main_runs_every_module_init :: proc(t: ^testing.T) {
	output := compile_text(t, "const x = 1;\nconsole.log(x);\n")
	text := llvm_text(t, &output, "program-init")
	if text == "" {
		return
	}
	// LLVM quotes a symbol that holds a dollar sign; lower spells a module init init$m<file>.
	wants := []string {
		"define void @tsnc_main()",
		"call void @\"init$m1\"(ptr null)",
		"define internal void @\"init$m1\"(ptr %env)",
		"@m1.x = internal global double",
	}
	expect_text(t, text, wants)
}

// console.log is one runtime call per statement: the values go in one array on the stack, and a
// string among them is a static cell.
@(test)
console_log_passes_its_values_in_one_call :: proc(t: ^testing.T) {
	output := compile_text(t, "console.log(1, \"ok\", true);\nconsole.log();\n")
	text := llvm_text(t, &output, "program-console")
	if text == "" {
		return
	}
	wants := []string {
		"[2 x i16] [i16 111, i16 107]",
		"alloca [3 x %tsnc.tagged]",
		"call void @tsnc_console_log(i64 0, ptr %",
		", i64 3)",
		"call void @tsnc_console_log(i64 0, ptr null, i64 0)",
	}
	expect_text(t, text, wants)
	testing.expectf(t, strings.count(text, "call void @tsnc_console_log") == 2, "%s", text)
}

// A program without roots still hands the runtime a slice. No program shows that a tagged global
// is a root: a stale copy on the stack keeps its cell alive through the conservative scan, and a
// mutation that dropped the row passed the corpus under stress (2026-09-27).
@(test)
globals_that_hold_a_reference_become_roots :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	array := ir.array_layout(&p, .Number)
	ir.add_global(&p, "g.number", ir.F64)
	ir.add_global(&p, "g.text", ir.STR)
	ir.add_global(&p, "g.flag", ir.BOOL)
	ir.add_global(&p, "g.value", ir.TAGGED)
	ir.add_global(&p, "g.closure", ir.CLOSURE)
	ir.add_global(&p, "g.array", ir.Type{kind = .Ref, layout = array})
	output := finish_program(t, &p, declare_main(&p))
	// Slot kinds: Ref 2, Tagged 3.
	wants := []string {
		"define ptr @tsnc_roots()",
		"define ptr @tsnc_ascii_cells()",
		"ret ptr @roots.slice",
		"@roots.slice = private constant { ptr, i64 } { ptr @roots, i64 4 }",
		"{ ptr @g.text, i8 2 }",
		"{ ptr @g.value, i8 3 }",
		"{ ptr @g.closure, i8 2 }",
		"{ ptr @g.array, i8 2 }",
	}
	expect_text(t, llvm_text(t, &output, "program-roots"), wants)

	empty := hello_program("no roots")
	no_roots := []string{"@roots.slice = private constant { ptr, i64 } zeroinitializer"}
	expect_text(t, llvm_text(t, &empty, "program-no-roots"), no_roots)
}

// A small cell comes off its free list inline, so tsnc_alloc stands only in the block the fast
// path falls back to, alone before the jump to the join. The closure takes the builtin table 2.
@(test)
a_small_cell_calls_the_runtime_only_on_the_slow_path :: proc(t: ^testing.T) {
	source :=
		"function counter(): () => number {\n" +
		"  let n = 0;\n" +
		"  return () => ++n;\n" +
		"}\n" +
		"const p = { a: 1, b: 2 };\n" +
		"console.log(p.a, counter()());\n"
	output := compile_text(t, source)
	text := llvm_text(t, &output, "program-alloc")
	if text == "" {
		return
	}
	wants := []string {
		"@heap = internal global ptr null",
		"define void @tsnc_heap(ptr %0)",
		"store ptr %0, ptr @heap",
		"call ptr @tsnc_alloc(i64 2)",
		"icmp sle i64",
		"= and i1 ",
	}
	expect_text(t, text, wants)

	lines := strings.split_lines(text, context.temp_allocator)
	calls := 0
	for line, i in lines {
		if !strings.contains(line, "call ptr @tsnc_alloc(") {
			continue
		}
		calls += 1
		alone :=
			strings.contains(lines[i - 1], "; preds = %") &&
			strings.has_prefix(lines[i + 1], "  br label %")
		testing.expectf(
			t,
			alone,
			"a call outside a slow block:\n%s\n%s\n%s",
			lines[i - 1],
			line,
			lines[i + 1],
		)
	}
	testing.expectf(t, calls >= 3, "%d calls of tsnc_alloc", calls)
	testing.expect_value(t, strings.count(text, "load ptr, ptr @heap"), calls)
}

// Two stores need the write barrier: into `inner` after a join, which may collect and so make it
// old, and into the parameter. The fields of a literal follow its allocation, a field it computes
// too, and a constant names no cell of the heap.
@(test)
only_a_store_into_a_cell_that_may_be_old_is_remembered :: proc(t: ^testing.T) {
	source :=
		"interface Box {\n" +
		"  item: Box | null;\n" +
		"  name: string;\n" +
		"}\n" +
		"function wrap(outer: Box): void {\n" +
		"  const inner: Box = { item: null, name: outer.name + \"!\" };\n" +
		"  inner.name = inner.name + \"?\";\n" +
		"  outer.item = inner;\n" +
		"  outer.name = \"x\";\n" +
		"}\n" +
		"const top: Box = { item: null, name: \"top\" };\n" +
		"wrap(top);\n" +
		"console.log(top.name);\n"
	output := compile_text(t, source)
	text := llvm_text(t, &output, "program-barrier")
	if text == "" {
		return
	}
	expect_text(t, text, []string{"declare void @tsnc_remember(ptr)", "and i32 ", "icmp eq i32 "})
	testing.expect_value(t, strings.count(text, "call void @tsnc_remember("), 2)
}

// A cell past abi.MAX_SMALL takes whole pages, which only the runtime hands out.
@(test)
a_large_cell_calls_the_runtime_at_once :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	slots := make([]abi.Slot_Kind, abi.MAX_SMALL / 8, context.temp_allocator)
	large := ir.environment_layout(&p, slots)
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, at(0))
	f := ir.begin_func(&p, main)
	ir.emit(&f, ir.Type{kind = .Ref, layout = large}, ir.Alloc{layout = large}, at(0))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(0))
	ir.end_func(&f)
	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "program-large-alloc")
	expect_text(t, text, []string{fmt.tprintf("call ptr @tsnc_alloc(i64 %d)", ir.table_id(large))})
	testing.expectf(t, !strings.contains(text, "load ptr, ptr @heap"), "an inline path:\n%s", text)
}
