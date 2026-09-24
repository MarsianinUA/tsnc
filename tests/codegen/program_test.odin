package codegen_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/codegen"
import "../../src/ir"
import "../../src/target"

/*
The whole compiler end to end: a TypeScript source through parse, bind, program, check and lower,
and the IR it answers through codegen to an object file. emit runs the LLVM module verifier itself,
so an accepted module is the assertion these tests care about.
*/

@(test)
a_program_builds_an_object_and_llvm_ir :: proc(t: ^testing.T) {
	Source :: struct {
		name: string,
		text: string,
	}
	sources := []Source {
		{
			"arithmetic",
			`
			const a = 2 + 3 * 4 - 1;
			const b = a % 5;
			const c = a / 2;
			const d = a ** 2;
			const e = (a | 1) ^ (b & 3);
			const f = (a << 2) >>> 1;
			const g = ~a >> 1;
			const h = -a;
			const equal = a === b;
			console.log(a + b + c + d + e + f + g + h);
			console.log(equal, a !== b, !equal);
		`,
		},
		{
			"control_flow",
			`
			function classify(n: number): number {
				let total = 0;
				for (let i = 0; i < n; i = i + 1) {
					if (i % 2 === 0) {
						continue;
					}
					total = total + i;
				}
				let k = n;
				while (k > 0) {
					k = k - 1;
					if (k === 3) {
						break;
					}
				}
				do {
					k = k + 1;
				} while (k < 2);
				switch (total) {
				case 0:
					return k;
				case 1:
					return k + 1;
				default:
					return total + k;
				}
			}
			console.log(classify(10));
		`,
		},
		{
			"functions",
			`
			function fib(n: number): number {
				if (n < 2) {
					return n;
				}
				return fib(n - 1) + fib(n - 2);
			}
			function pick(x: number, y: number): number {
				const larger = x > y ? x : y;
				const both = x > 0 && y > 0;
				const either = x > 0 || y > 0;
				return both === either ? larger : fib(3);
			}
			console.log(pick(1, 2));
		`,
		},
		{
			"builtins",
			`
			const rooted = Math.sqrt(Math.abs(-9));
			const rounded = Math.round(1.5);
			const bounded = Math.min(Math.max(rooted, 1), 10);
			const raised = Math.pow(2, 10);
			console.log(rooted + rounded + bounded + raised);
			console.error("done", true, 1);
			if (rounded < 0) {
				process.exit(1);
			}
		`,
		},
		{
			"heap",
			`
			interface Point { x: number; y: number; }
			interface Loose { x: number | string; y: number; }
			function widen(p: Point): Loose { return p; }
			const points: Point[] = [{ y: 2, x: 1 }, { x: 3, y: 4 }];
			points[points.length] = { x: 5, y: 6 };
			const sums = points.map((p, i) => p.x + p.y + i);
			const big = points.filter(p => p.x > 2);
			let total = 0;
			points.forEach(p => { total += widen(p).y; });
			const joined = sums.reduce((text, n) => text + n + ",", "");
			for (const c of "ab") {
				total += c.length;
			}
			console.log(points[0].x, big.length, total, joined.slice(1), joined + "!" < "z");
		`,
		},
	}

	for source in sources {
		output := compile_text(t, source.text)
		unit := output.units[0]
		object := fmt.tprintf("dist/codegen-%s.obj", source.name)
		if err := codegen.emit(&output, unit, target.HOST, .speed, .Object, object);
		   !testing.expectf(t, err == .None, "%s: object: %v", source.name, err) {
			continue
		}
		path := fmt.tprintf("dist/codegen-%s.ll", source.name)
		err := codegen.emit(&output, unit, target.HOST, .speed, .LLVM_IR, path)
		testing.expectf(t, err == .None, "%s: text: %v", source.name, err)
	}
}

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
		"call void @\"init$m1\"()",
		"define internal void @\"init$m1\"()",
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

// Every layout reaches the object file as the type table the runtime registers at startup, in the
// order ir.table_id numbers them, and a program without layouts still hands the runtime a slice.
@(test)
layouts_become_the_type_tables_the_runtime_reads :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	fields := [?]ir.Slot {
		{name = "next", kind = .Ref},
		{name = "x", kind = .Number, optional = true},
	}
	ir.object_layout(&p, fields[:])
	captured := [?]abi.Slot_Kind{.Tagged}
	ir.environment_layout(&p, captured[:])
	ir.array_layout(&p, .Ref)
	output := finish_program(t, &p, declare_main(&p))
	// Slot kinds: Number 0, Ref 2, Tagged 3; cell kinds: Object 0, Environment 1, Array 3. The
	// last byte of a field says whether it is optional.
	wants := []string {
		"define ptr @tsnc_type_tables()",
		"ret ptr @type_tables.slice",
		"@type_tables.slice = private constant { ptr, i64 } { ptr @type_tables, i64 3 }",
		"{ i8 0, i64 24, ptr @fields, i64 2, i8 0 }",
		"{ ptr @text, i64 4, i64 8, i8 2, i8 0 }",
		"{ ptr, i64, i64, i8, i8 } { ptr @text.1, i64 1, i64 16, i8 0, i8 1 }",
		"@text = private unnamed_addr constant [4 x i8] c\"next\"",
		"{ i8 1, i64 24, ptr @fields.2, i64 1, i8 0 }",
		"{ ptr null, i64 0, i64 8, i8 3, i8 0 }",
		"{ i8 3, i64 32, ptr null, i64 0, i8 2 }",
	}
	expect_text(t, llvm_text(t, &output, "program-tables"), wants)

	empty := hello_program("no layouts")
	no_tables := []string{"@type_tables.slice = private constant { ptr, i64 } zeroinitializer"}
	expect_text(t, llvm_text(t, &empty, "program-no-tables"), no_tables)
}

// A program without roots still hands the runtime a slice.
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
