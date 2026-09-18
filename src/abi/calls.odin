package abi

// MAIN_SYMBOL names the generated entry point, proc "c" (). The runtime's main calls it once, after
// setting up the Odin context.
MAIN_SYMBOL :: "tsnc_main"

// C_Type is the type of a runtime export parameter or result in the C calling convention; codegen
// maps each to one LLVM type.
C_Type :: enum u8 {
	Void,
	Ptr,
}

// Runtime_Proc lists the procedures the runtime exports to generated code. Runtime tasks add rows
// as they add exports.
Runtime_Proc :: enum u8 {
	Log_String, // (text: ^String_Cell): the units as UTF-8 and a newline to stdout
	Fail, // (site: ^Fail_Site): a message to stderr, then exit code 1
}

Runtime_Export :: struct {
	symbol: string,
	params: []C_Type,
	result: C_Type,
}

// RUNTIME_EXPORTS gives each runtime export its symbol and C signature. The runtime names its
// exports from it (`@(export, link_name = ...)`) and codegen declares them from the same rows.
// Every symbol starts with `tsnc_` to stay clear of libc and Odin.
RUNTIME_EXPORTS :: [Runtime_Proc]Runtime_Export {
	.Log_String = {symbol = "tsnc_log_string", params = {.Ptr}, result = .Void},
	.Fail = {symbol = "tsnc_fail", params = {.Ptr}, result = .Void},
}

Runtime_Error :: enum i32 {
	Index_Out_Of_Range, // a read out of range, or a write past `length`
	Index_Not_Integer,
	Non_Null_Assertion, // `x!` on null or undefined
	Type_Assertion, // an `as` that narrows a union fails its tag check
	Out_Of_Memory,
	Internal, // an assertion inside the runtime
}

// Fail_Site records where generated code failed. The compiler emits one constant per failure point
// and passes its address to tsnc_fail, the way Rust passes a static Location to its panic
// procedures.
Fail_Site :: struct {
	file:   string, // source path, UTF-8
	line:   i32,
	column: i32, // same unit as diagnostics
	error:  Runtime_Error,
}
