package link_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/codegen"
import "../../src/ir"
import "../../src/link"
import "../../src/source"
import "../../src/target"

// The test runner runs tests on a thread pool, so LLVM's process-global setup happens once before
// the pool starts, the way driver sets it up before its own pool.
@(init)
init_llvm :: proc "contextless" () {
	codegen.init_global_options()
}

// link finds the runtime object next to the test executable, in dist/, so it has to be built
// before these tests run.
RUNTIME_BUILD :: "odin build src/runtime -build-mode:obj -use-single-module -out:dist/tsnc_rt-<target>.obj -vet -strict-style"

// HELLO is printed by IR built by hand rather than compiled from a source: these tests say nothing
// about the front end.
HELLO :: "Hello, world!"

// TAGGED_ANSWERS is what Node prints for the questions tagged_program asks, one per line:
//
//	for (const v of [typeof 1.5, typeof undefined, String(-0), String("abc"), String(true),
//		NaN === NaN, -0 === 0, "12" === String(12), !!"", !!1.5, !!null]) console.log(v)
TAGGED_ANSWERS :: "number\nundefined\n0\nabc\ntrue\nfalse\ntrue\ntrue\nfalse\ntrue\nfalse\n"

// ARRAY_ANSWERS is what Node prints for the steps of array_program, one per line:
//
//	const pieces = "c,a,b".split(",");
//	for (const v of [pieces.pop(), pieces.push("d"), pieces.indexOf("a"), pieces.includes("z"),
//		pieces.slice(1).join("-"), String(pieces.sort()), pieces.slice(0, 0).pop()]) console.log(String(v))
ARRAY_ANSWERS :: "b\n3\n1\nfalse\na-d\na,c,d\nundefined\n"

// ARGUMENTS reach process.argv as they were passed: the Cyrillic one in UTF-16, which on Windows
// means from the wide command line, and the quotes as the command line escaped them.
ARGUMENTS :: []string{"a", "\xd0\xb1 \xd0\xb2", "\"q\""}

// console_answers is what Node prints for console_program as a single executable application
// named `name` and run with ARGUMENTS, whose process.argv is [execPath, argv[0], ...arguments]:
//
//	console.log(process.argv); console.log(process.argv.join("\n"));
//	console.log("c,a,b".split(","), 1.5, "x", null, undefined, true, -0);
//	console.error("%s=%d%%", "n", 42)
//
// The two paths make the array too long for one line.
console_answers :: proc(name: string) -> string {
	dir, _ := os.get_executable_directory(context.temp_allocator)
	program, _ := os.join_path({dir, fmt.tprintf("%s.exe", name)}, context.temp_allocator)
	quoted, _ := strings.replace_all(program, "\\", "\\\\", context.temp_allocator)
	return fmt.tprintf(
		"[\n  '%s',\n  '%s',\n  'a',\n  '\xd0\xb1 \xd0\xb2',\n  '\"q\"'\n]\n" +
		"%s\n%s\na\n\xd0\xb1 \xd0\xb2\n\"q\"\n" +
		"[ 'c', 'a', 'b' ] 1.5 x null undefined true -0\n",
		quoted,
		quoted,
		program,
		program,
	)
}

NAN :: 0h7ff8_0000_0000_0000
INF :: 0h7ff0_0000_0000_0000
NEGATIVE_ZERO :: 0h8000_0000_0000_0000

SPAN :: source.Span {
	file  = 0,
	start = 0,
	end   = 1,
}

@(test)
hello_world_links_and_runs :: proc(t: ^testing.T) {
	output := hello_program()
	state, stdout, stderr, ran := build_and_run(t, &output, "link-hello")
	if !ran {
		return
	}
	testing.expect_value(t, stdout, HELLO + "\n")
	testing.expect_value(t, stderr, "")
	testing.expect_value(t, state.exit_code, 0)

	// The executable exports nothing, so lld-link writes no import library next to it. It did
	// while the runtime marked its procedures @(export), which is dllexport on Windows.
	when ODIN_OS == .Windows {
		dir, _ := os.get_executable_directory(context.temp_allocator)
		import_library, _ := os.join_path({dir, "link-hello.lib"}, context.temp_allocator)
		testing.expectf(t, !os.exists(import_library), "%s was written", import_library)
	}
}

// A tagged value crosses into the runtime as two words (abi.C_Type.Tagged). Only a program that
// codegen built and the linker joined to the runtime shows that both sides pass those words the
// same way, on each target CI runs.
@(test)
tagged_values_cross_into_the_runtime :: proc(t: ^testing.T) {
	output := tagged_program()
	state, stdout, stderr, ran := build_and_run(t, &output, "link-tagged")
	if !ran {
		return
	}
	testing.expect_value(t, stdout, TAGGED_ANSWERS)
	testing.expect_value(t, stderr, "")
	testing.expect_value(t, state.exit_code, 0)
}

// Arrays cross in both directions: an element goes in as a tagged value and comes out of pop through
// the slot codegen passes (abi.C_Type.Tagged), and the runtime finds the program's `string[]` table
// for split among the ones codegen wrote.
@(test)
arrays_cross_into_the_runtime :: proc(t: ^testing.T) {
	output := array_program()
	state, stdout, stderr, ran := build_and_run(t, &output, "link-arrays")
	if !ran {
		return
	}
	testing.expect_value(t, stdout, ARRAY_ANSWERS)
	testing.expect_value(t, stderr, "")
	testing.expect_value(t, state.exit_code, 0)
}

// console_program prints process.argv, run with ARGUMENTS, as console.log(argv) and as
// argv.join("\n"), then a split array and tagged values on one line and a format string on stderr.
// Each statement is one runtime call that takes its values on the caller's stack.
@(test)
console_and_process_argv_cross_into_the_runtime :: proc(t: ^testing.T) {
	output := console_program()
	state, stdout, stderr, ran := build_and_run(t, &output, "link-console", ARGUMENTS)
	if !ran {
		return
	}
	testing.expect_value(t, stdout, console_answers("link-console"))
	testing.expect_value(t, stderr, "n=42%\n")
	testing.expect_value(t, state.exit_code, 0)
}

// The same program in GC stress mode, which collects before every allocation: process.argv is
// built one cell at a time, and every cell has to survive the allocation of the next.
@(test)
console_and_process_argv_survive_a_collection_at_every_allocation :: proc(t: ^testing.T) {
	output := console_program()
	environment, _ := os.environ(context.temp_allocator)
	stress := make([dynamic]string, context.temp_allocator)
	append(&stress, ..environment)
	append(&stress, "TSNC_GC_STRESS=1")
	name := "link-console-stress"
	state, stdout, stderr, ran := build_and_run(t, &output, name, ARGUMENTS, stress[:])
	if !ran {
		return
	}
	testing.expect_value(t, stdout, console_answers(name))
	testing.expect_value(t, stderr, "n=42%\n")
	testing.expect_value(t, state.exit_code, 0)
}

@(test)
missing_runtime_object_is_reported :: proc(t: ^testing.T) {
	missing := "dist/link-missing/tsnc_rt.obj"
	err := link.link({"dist/link-hello.obj"}, target.HOST, "dist/link-missing.exe", missing)
	defer delete(err.detail)
	testing.expect_value(t, err.kind, link.Error_Kind.Runtime_Object_Missing)
	testing.expect_value(t, err.detail, missing)
}

// Without a program object nothing defines tsnc_main, which the runtime calls. lld-link, GNU ld and
// ld64 all name the undefined symbol.
@(test)
linker_stderr_reaches_the_error :: proc(t: ^testing.T) {
	err := link.link({}, target.HOST, "dist/link-no-program.exe")
	defer delete(err.detail)
	testing.expectf(t, err.kind == .Linker_Failed, "%v: %s", err.kind, err.detail)
	testing.expectf(
		t,
		strings.contains(err.detail, "tsnc_main"),
		"the linker's stderr lacks tsnc_main:\n%s",
		err.detail,
	)
}

@(test)
only_the_host_target_links :: proc(t: ^testing.T) {
	for id in target.Target {
		if id == target.HOST {
			continue
		}
		err := link.link({"dist/link-hello.obj"}, id, "dist/link-other.exe")
		testing.expectf(t, err.kind == .Unsupported_Target, "%v: %v", id, err.kind)
		testing.expect_value(t, err.detail, "")
	}
}

// build_and_run emits the program as an object, links it with the runtime object under `name` in
// the test's directory and runs it with `arguments`, in `environment` when it is not nil.
@(private = "file")
build_and_run :: proc(
	t: ^testing.T,
	output: ^ir.Program_IR,
	name: string,
	arguments: []string = nil,
	environment: []string = nil,
	loc := #caller_location,
) -> (
	state: os.Process_State,
	stdout: string,
	stderr: string,
	ran: bool,
) {
	object := fmt.tprintf("dist/%s.obj", name)
	emit_err := codegen.emit(output, output.units[0], target.HOST, .speed, .Object, object)
	if !testing.expect_value(t, emit_err, codegen.Error.None, loc = loc) {
		return
	}

	// An absolute path, so the run below does not depend on how the OS resolves a relative one.
	dir, _ := os.get_executable_directory(context.temp_allocator)
	program, _ := os.join_path({dir, fmt.tprintf("%s.exe", name)}, context.temp_allocator)
	err := link.link({object}, target.HOST, program)
	defer delete(err.detail)
	if !testing.expectf(
		t,
		err.kind == .None,
		"%v: %s\nbuild the runtime object first: %s",
		err.kind,
		err.detail,
		RUNTIME_BUILD,
		loc = loc,
	) {
		return
	}

	out, errors: []byte
	run_err: os.Error
	command := make([dynamic]string, context.temp_allocator)
	append(&command, program)
	append(&command, ..arguments)
	description := os.Process_Desc {
		command = command[:],
		env     = environment,
	}
	state, out, errors, run_err = os.process_exec(description, context.temp_allocator)
	if !testing.expectf(t, run_err == nil, "run %s: %v", program, run_err, loc = loc) {
		return
	}
	return state, string(out), string(errors), true
}

// hello_program is the smallest program there is: tsnc_main prints one line through the runtime.
// Its layouts are there for the runtime's main, which registers the type tables codegen wrote for
// them before it calls tsnc_main: a table the runtime cannot read ends the run with exit code 1.
@(private = "file")
hello_program :: proc() -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)
	fields := [?]ir.Slot{{name = "next", kind = .Ref}, {name = "value", kind = .Tagged}}
	ir.object_layout(&p, fields[:])
	captured := [?]abi.Slot_Kind{.Number, .Boolean}
	ir.environment_layout(&p, captured[:])
	ir.array_layout(&p, .Tagged)
	line := ir.intern_string(&p, HELLO)
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, SPAN)
	f := ir.begin_func(&p, main)
	cell := ir.emit(&f, ir.STR, ir.Const_String{text = line}, SPAN)
	args := [?]ir.Value_ID{cell}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Log_String, args = args[:]}, SPAN)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, SPAN)
	ir.end_func(&f)
	return ir.finish(&p, main, nil)
}

// tagged_program asks each question of TAGGED_ANSWERS through the Value exports, with one tagged
// argument and with two, and prints each answer as its own line. A boolean answer goes back into a
// tagged value, so Value_To_String spells it.
@(private = "file")
tagged_program :: proc() -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)
	abc := ir.intern_string(&p, "abc")
	twelve := ir.intern_string(&p, "12")
	empty := ir.intern_string(&p, "")
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, SPAN)
	f := ir.begin_func(&p, main)

	nan := boxed_number(&f, NAN)
	negative_zero := boxed_number(&f, NEGATIVE_ZERO)
	zero := boxed_number(&f, 0)
	one_and_a_half := boxed_number(&f, 1.5)
	undefined := ir.emit(&f, ir.TAGGED, ir.Const_Undefined{}, SPAN)
	null := ir.emit(&f, ir.TAGGED, ir.Const_Null{}, SPAN)
	yes := box(&f, ir.emit(&f, ir.BOOL, ir.Const_Bool{value = true}, SPAN))
	abc_text := box(&f, ir.emit(&f, ir.STR, ir.Const_String{text = abc}, SPAN))
	twelve_text := box(&f, ir.emit(&f, ir.STR, ir.Const_String{text = twelve}, SPAN))
	empty_text := box(&f, ir.emit(&f, ir.STR, ir.Const_String{text = empty}, SPAN))

	write_line(&f, call(&f, .Value_Typeof, ir.STR, one_and_a_half))
	write_line(&f, call(&f, .Value_Typeof, ir.STR, undefined))
	write_line(&f, call(&f, .Value_To_String, ir.STR, negative_zero))
	write_line(&f, call(&f, .Value_To_String, ir.STR, abc_text))
	write_line(&f, call(&f, .Value_To_String, ir.STR, yes))
	write_boolean(&f, call(&f, .Value_Equal, ir.BOOL, nan, nan))
	write_boolean(&f, call(&f, .Value_Equal, ir.BOOL, negative_zero, zero))
	// A static cell against one the runtime built: equal by content.
	computed := box(&f, call(&f, .Value_To_String, ir.STR, boxed_number(&f, 12)))
	write_boolean(&f, call(&f, .Value_Equal, ir.BOOL, twelve_text, computed))
	write_boolean(&f, call(&f, .Value_To_Boolean, ir.BOOL, empty_text))
	write_boolean(&f, call(&f, .Value_To_Boolean, ir.BOOL, one_and_a_half))
	write_boolean(&f, call(&f, .Value_To_Boolean, ir.BOOL, null))

	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, SPAN)
	ir.end_func(&f)
	return ir.finish(&p, main, nil)
}

// array_program takes each step of ARRAY_ANSWERS through the String_Split and Array exports and
// prints what it answers.
@(private = "file")
array_program :: proc() -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)
	strings_type := ir.ref(ir.array_layout(&p, .Ref))
	cab := ir.intern_string(&p, "c,a,b")
	comma := ir.intern_string(&p, ",")
	dash := ir.intern_string(&p, "-")
	a := ir.intern_string(&p, "a")
	d := ir.intern_string(&p, "d")
	z := ir.intern_string(&p, "z")
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, SPAN)
	f := ir.begin_func(&p, main)

	text := ir.emit(&f, ir.STR, ir.Const_String{text = cab}, SPAN)
	separator := ir.emit(&f, ir.STR, ir.Const_String{text = comma}, SPAN)
	no_limit := number(&f, abi.MISSING_LIMIT)
	zero := number(&f, 0)
	pieces := call(&f, .String_Split, strings_type, text, separator, no_limit)

	write_line(&f, call(&f, .Value_To_String, ir.STR, call(&f, .Array_Pop, ir.TAGGED, pieces)))
	pushed := call(&f, .Array_Push, ir.F64, pieces, boxed_string(&f, d))
	write_line(&f, call(&f, .Number_To_String, ir.STR, pushed))
	found := call(&f, .Array_Index_Of, ir.F64, pieces, boxed_string(&f, a), zero)
	write_line(&f, call(&f, .Number_To_String, ir.STR, found))
	write_boolean(&f, call(&f, .Array_Includes, ir.BOOL, pieces, boxed_string(&f, z), zero))
	tail := call(&f, .Array_Slice, strings_type, pieces, number(&f, 1), number(&f, INF))
	joiner := ir.emit(&f, ir.STR, ir.Const_String{text = dash}, SPAN)
	write_line(&f, call(&f, .Array_Join, ir.STR, tail, joiner))
	sorted := call(&f, .Array_Sort_Default, strings_type, pieces)
	write_line(&f, call(&f, .Value_To_String, ir.STR, box(&f, sorted)))
	empty := call(&f, .Array_Slice, strings_type, pieces, zero, zero)
	write_line(&f, call(&f, .Value_To_String, ir.STR, call(&f, .Array_Pop, ir.TAGGED, empty)))

	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, SPAN)
	ir.end_func(&f)
	return ir.finish(&p, main, nil)
}

// console_program is the program console_answers describes, built by hand: until milestone 5
// lowers arrays, no TypeScript source can pass one to console.log.
@(private = "file")
console_program :: proc() -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)
	strings_type := ir.ref(ir.array_layout(&p, .Ref))
	line_end := ir.intern_string(&p, "\n")
	cab := ir.intern_string(&p, "c,a,b")
	comma := ir.intern_string(&p, ",")
	x := ir.intern_string(&p, "x")
	pattern := ir.intern_string(&p, "%s=%d%%")
	n := ir.intern_string(&p, "n")
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, SPAN)
	f := ir.begin_func(&p, main)

	argv := call(&f, .Process_Argv, strings_type)
	log(&f, false, box(&f, argv))
	separator := ir.emit(&f, ir.STR, ir.Const_String{text = line_end}, SPAN)
	log(&f, false, box(&f, call(&f, .Array_Join, ir.STR, argv, separator)))

	text := ir.emit(&f, ir.STR, ir.Const_String{text = cab}, SPAN)
	splitter := ir.emit(&f, ir.STR, ir.Const_String{text = comma}, SPAN)
	pieces := call(&f, .String_Split, strings_type, text, splitter, number(&f, abi.MISSING_LIMIT))
	log(
		&f,
		false,
		box(&f, pieces),
		boxed_number(&f, 1.5),
		boxed_string(&f, x),
		ir.emit(&f, ir.TAGGED, ir.Const_Null{}, SPAN),
		ir.emit(&f, ir.TAGGED, ir.Const_Undefined{}, SPAN),
		box(&f, ir.emit(&f, ir.BOOL, ir.Const_Bool{value = true}, SPAN)),
		boxed_number(&f, NEGATIVE_ZERO),
	)
	log(&f, true, boxed_string(&f, pattern), boxed_string(&f, n), boxed_number(&f, 42))

	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, SPAN)
	ir.end_func(&f)
	return ir.finish(&p, main, nil)
}

// log is console.log, or console.error when `err` is true.
@(private = "file")
log :: proc(f: ^ir.Func_Builder, err: bool, values: ..ir.Value_ID) {
	args := make([]ir.Value_ID, len(values) + 1, context.temp_allocator)
	args[0] = ir.emit(f, ir.BOOL, ir.Const_Bool{value = err}, SPAN)
	copy(args[1:], values)
	ir.emit(f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = args}, SPAN)
}

@(private = "file")
number :: proc(f: ^ir.Func_Builder, n: f64) -> ir.Value_ID {
	return ir.emit(f, ir.F64, ir.Const_Number{value = n}, SPAN)
}

@(private = "file")
boxed_string :: proc(f: ^ir.Func_Builder, text: ir.String_ID) -> ir.Value_ID {
	return box(f, ir.emit(f, ir.STR, ir.Const_String{text = text}, SPAN))
}

@(private = "file")
boxed_number :: proc(f: ^ir.Func_Builder, n: f64) -> ir.Value_ID {
	return box(f, number(f, n))
}

@(private = "file")
box :: proc(f: ^ir.Func_Builder, value: ir.Value_ID) -> ir.Value_ID {
	return ir.emit(f, ir.TAGGED, ir.Box{value = value}, SPAN)
}

@(private = "file")
call :: proc(
	f: ^ir.Func_Builder,
	export: abi.Runtime_Proc,
	type: ir.Type,
	args: ..ir.Value_ID,
) -> ir.Value_ID {
	return ir.emit(f, type, ir.Call_Runtime{export = export, args = args}, SPAN)
}

@(private = "file")
write_line :: proc(f: ^ir.Func_Builder, text: ir.Value_ID) {
	call(f, .Log_String, ir.VOID, text)
}

@(private = "file")
write_boolean :: proc(f: ^ir.Func_Builder, answer: ir.Value_ID) {
	write_line(f, call(f, .Value_To_String, ir.STR, box(f, answer)))
}
