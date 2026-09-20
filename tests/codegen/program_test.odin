package codegen_tests

import "core:fmt"
import "core:testing"

import "../../src/codegen"
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

// tsnc_main is the one symbol that leaves the object file, and it calls the init of every module in
// the order the program graph put them.
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

// A string argument of console.log goes to the runtime as a static cell, one call per argument.
@(test)
console_log_passes_a_static_cell_to_the_runtime :: proc(t: ^testing.T) {
	output := compile_text(t, "console.log(\"ok\");\n")
	text := llvm_text(t, &output, "program-console")
	if text == "" {
		return
	}
	wants := []string{"[2 x i16] [i16 111, i16 107]", "call void @tsnc_console_string(i64 0, ptr"}
	expect_text(t, text, wants)
}
