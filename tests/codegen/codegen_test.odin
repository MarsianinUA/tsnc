package codegen_tests

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "../../src/codegen"
import "../../src/target"

// The test runner runs tests on a thread pool, so LLVM's process-global setup happens once before
// the pool starts, the way driver sets it up before its own pool.
@(init)
init_llvm :: proc "contextless" () {
	codegen.init_global_options()
}

// dist/hello.obj and dist/hello.ll are the same module as an object file and as text.
@(test)
hello_world_writes_object_and_llvm_ir :: proc(t: ^testing.T) {
	object_err := codegen.emit(codegen.Unit{}, target.HOST, .speed, .Object, "dist/hello.obj")
	testing.expect_value(t, object_err, codegen.Error.None)
	ir_err := codegen.emit(codegen.Unit{}, target.HOST, .speed, .LLVM_IR, "dist/hello.ll")
	testing.expect_value(t, ir_err, codegen.Error.None)

	object, object_read_err := os.read_entire_file("dist/hello.obj", context.allocator)
	defer delete(object)
	testing.expectf(t, object_read_err == nil, "read dist/hello.obj: %v", object_read_err)
	testing.expect(t, len(object) > 0, "dist/hello.obj is empty")

	ir, ir_read_err := os.read_entire_file("dist/hello.ll", context.allocator)
	defer delete(ir)
	if !testing.expectf(t, ir_read_err == nil, "read dist/hello.ll: %v", ir_read_err) {
		return
	}
	wants := []string {
		fmt.tprintf("target triple = \"%s\"", target.SPECS[target.HOST].triple),
		"define void @tsnc_main()",
		"call void @tsnc_log_string(ptr",
		// HELLO_WORLD as an abi.String_Cell in read-only data: the String type table, no flags,
		// 13 UTF-16 units.
		"private unnamed_addr constant { i32, i32, i64, [13 x i16] } { i32 0, i32 0, i64 13,",
		"[13 x i16] [i16 72, i16 101, i16 108, i16 108, i16 111, i16 44, i16 32, i16 119,",
		"i16 111, i16 114, i16 108, i16 100, i16 33] }, align 8",
	}
	for want in wants {
		testing.expectf(
			t,
			strings.contains(string(ir), want),
			"dist/hello.ll lacks %q:\n%s",
			want,
			string(ir),
		)
	}
}

// tsnc_fail never returns, so LLVM may treat the code after its call as unreachable. Level none
// keeps the declaration: the stub does not call tsnc_fail, and the optimizer drops it.
@(test)
diverging_export_is_declared_noreturn :: proc(t: ^testing.T) {
	path := "dist/codegen-noreturn.ll"
	err := codegen.emit(codegen.Unit{}, target.HOST, .none, .LLVM_IR, path)
	if !testing.expect_value(t, err, codegen.Error.None) {
		return
	}
	ir, read_err := os.read_entire_file(path, context.allocator)
	defer delete(ir)
	if !testing.expectf(t, read_err == nil, "read %s: %v", path, read_err) {
		return
	}
	// On Windows LLVM writes the text with CRLF, so the patterns stop short of the line end.
	wants := []string{"declare void @tsnc_fail(ptr) #0", "attributes #0 = { noreturn }"}
	for want in wants {
		testing.expectf(
			t,
			strings.contains(string(ir), want),
			"%s lacks %q:\n%s",
			path,
			want,
			string(ir),
		)
	}
	returning := "declare void @tsnc_log_string(ptr) #"
	testing.expectf(
		t,
		!strings.contains(string(ir), returning),
		"tsnc_log_string has attributes:\n%s",
		string(ir),
	)
}

@(test)
every_level_emits_an_object :: proc(t: ^testing.T) {
	for level in codegen.Optimization {
		path := fmt.tprintf("dist/codegen-%v.obj", level)
		err := codegen.emit(codegen.Unit{}, target.HOST, level, .Object, path)
		testing.expectf(t, err == .None, "%v: %v", level, err)
	}
}

// Every supported triple gets its own object format on any host, so the triple really reaches
// LLVM.
@(test)
every_supported_target_emits_its_object_format :: proc(t: ^testing.T) {
	// The first bytes of each format: the COFF machine type for x86-64, the ELF magic, the 64-bit
	// Mach-O magic, all little-endian.
	magics := #partial [target.Target]string {
		.windows_amd64 = "\x64\x86",
		.linux_amd64   = "\x7fELF",
		.darwin_arm64  = "\xcf\xfa\xed\xfe",
		.darwin_amd64  = "\xcf\xfa\xed\xfe",
	}
	for id in target.Target {
		if !target.supported(id) {
			continue
		}
		if !testing.expectf(t, magics[id] != "", "%v: no object format magic in this test", id) {
			continue
		}
		path := fmt.tprintf("dist/codegen-%v.obj", id)
		err := codegen.emit(codegen.Unit{}, id, .speed, .Object, path)
		if !testing.expectf(t, err == .None, "%v: %v", id, err) {
			continue
		}
		object, read_err := os.read_entire_file(path, context.allocator)
		defer delete(object)
		testing.expectf(t, read_err == nil, "read %s: %v", path, read_err)
		testing.expectf(
			t,
			strings.has_prefix(string(object), magics[id]),
			"%v: the object starts with %x",
			id,
			object[:min(len(object), 4)],
		)
	}
}

@(test)
target_without_a_row_is_unsupported :: proc(t: ^testing.T) {
	path := "dist/codegen-wasm32_wasi.obj"
	err := codegen.emit(codegen.Unit{}, .wasm32_wasi, .speed, .Object, path)
	testing.expect_value(t, err, codegen.Error.Unsupported_Target)
	testing.expectf(t, !os.exists(path), "%s was written", path)
}

@(test)
missing_directory_is_a_write_error :: proc(t: ^testing.T) {
	for artifact in codegen.Artifact {
		path := fmt.tprintf("dist/codegen-missing-directory/hello-%v", artifact)
		err: codegen.Error
		{
			// emit logs LLVM's reason at error level, and the test runner fails a test on any
			// error log. The scope keeps the expects below on the runner's logger.
			context.logger = log.nil_logger()
			err = codegen.emit(codegen.Unit{}, target.HOST, .speed, artifact, path)
		}
		testing.expectf(t, err == .Write_Failed, "%v: %v", artifact, err)
	}
}
