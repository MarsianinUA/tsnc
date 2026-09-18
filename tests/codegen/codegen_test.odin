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

V1_TARGETS :: bit_set[target.Target]{.windows_amd64, .linux_amd64, .darwin_arm64, .darwin_amd64}

// T1.7 links dist/hello.obj with the runtime object; dist/hello.ll is the same module as text.
@(test)
hello_world_writes_object_and_llvm_ir :: proc(t: ^testing.T) {
	object_err := codegen.emit(codegen.Unit{}, target.HOST, .Speed, .Object, "dist/hello.obj")
	testing.expect_value(t, object_err, codegen.Error.None)
	ir_err := codegen.emit(codegen.Unit{}, target.HOST, .Speed, .LLVM_IR, "dist/hello.ll")
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

@(test)
every_level_emits_an_object :: proc(t: ^testing.T) {
	for level in codegen.Optimization {
		path := fmt.tprintf("dist/codegen-%v.obj", level)
		err := codegen.emit(codegen.Unit{}, target.HOST, level, .Object, path)
		testing.expectf(t, err == .None, "%v: %v", level, err)
	}
}

// Every v1 triple gets its own object format on any host, so the triple really reaches LLVM.
@(test)
every_v1_target_emits_its_object_format :: proc(t: ^testing.T) {
	// The first bytes of each format: the COFF machine type for x86-64, the ELF magic, the 64-bit
	// Mach-O magic, all little-endian.
	magics := #partial [target.Target]string {
		.windows_amd64 = "\x64\x86",
		.linux_amd64   = "\x7fELF",
		.darwin_arm64  = "\xcf\xfa\xed\xfe",
		.darwin_amd64  = "\xcf\xfa\xed\xfe",
	}
	for id in V1_TARGETS {
		path := fmt.tprintf("dist/codegen-%v.obj", id)
		err := codegen.emit(codegen.Unit{}, id, .Speed, .Object, path)
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
	err := codegen.emit(codegen.Unit{}, .wasm32_wasi, .Speed, .Object, path)
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
			err = codegen.emit(codegen.Unit{}, target.HOST, .Speed, artifact, path)
		}
		testing.expectf(t, err == .Write_Failed, "%v: %v", artifact, err)
	}
}
