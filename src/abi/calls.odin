package abi

// MAIN_SYMBOL names the generated entry point, proc "c" (). The runtime's main calls it once, after
// setting up the Odin context.
MAIN_SYMBOL :: "tsnc_main"

// C_Type is the type of a runtime export parameter or result in the C calling convention; codegen
// maps each to one LLVM type. A boolean is b64 here, the width the package uses for a boolean slot,
// so no export depends on how a C compiler widens a narrower one.
C_Type :: enum u8 {
	Void,
	Ptr,
	Number, // f64
	Boolean, // b64, 0 or 1
}

// Runtime_Proc lists the procedures the runtime exports to generated code. Runtime tasks add rows
// as they add exports.
Runtime_Proc :: enum u8 {
	// Console output, requirements 3.9. One call writes one piece of a line: lower knows every
	// argument statically, so it composes the spaces between them and the line end out of string
	// constants and picks the row by the type of each argument.
	Console_String, // (err, text: ^String_Cell)
	Console_Number, // (err, value): the digits of requirements 3.1
	Console_Boolean, // (err, value): `true` or `false`
	Log_String, // (text: ^String_Cell): the units as UTF-8 and a newline to stdout
	Process_Exit, // (code): flushes nothing and ends the process
	// The three Math names that are not a C function: round takes a half toward positive infinity,
	// max and min have their own rules for NaN and -0 (requirements 4.5).
	Math_Round, // (x) -> f64
	Math_Max, // (a, b) -> f64
	Math_Min, // (a, b) -> f64
	Fail, // (site: ^Fail_Site): a message to stderr, then exit code 1
}

Runtime_Export :: struct {
	symbol:   string,
	params:   []C_Type,
	result:   C_Type,
	// The export never returns: the runtime declares it `-> !`, codegen declares it noreturn.
	diverges: bool,
}

// RUNTIME_EXPORTS gives each runtime export its symbol and C signature. The runtime names its
// exports from it (`@(export, link_name = ...)`) and codegen declares them from the same rows.
// Every symbol starts with `tsnc_` to stay clear of libc and Odin.
RUNTIME_EXPORTS :: [Runtime_Proc]Runtime_Export {
	.Console_String = {symbol = "tsnc_console_string", params = {.Boolean, .Ptr}, result = .Void},
	.Console_Number = {
		symbol = "tsnc_console_number",
		params = {.Boolean, .Number},
		result = .Void,
	},
	.Console_Boolean = {
		symbol = "tsnc_console_boolean",
		params = {.Boolean, .Boolean},
		result = .Void,
	},
	.Log_String = {symbol = "tsnc_log_string", params = {.Ptr}, result = .Void},
	.Process_Exit = {
		symbol = "tsnc_process_exit",
		params = {.Number},
		result = .Void,
		diverges = true,
	},
	.Math_Round = {symbol = "tsnc_math_round", params = {.Number}, result = .Number},
	.Math_Max = {symbol = "tsnc_math_max", params = {.Number, .Number}, result = .Number},
	.Math_Min = {symbol = "tsnc_math_min", params = {.Number, .Number}, result = .Number},
	.Fail = {symbol = "tsnc_fail", params = {.Ptr}, result = .Void, diverges = true},
}

Runtime_Error :: enum i32 {
	Index_Out_Of_Range, // a read out of range, or a write past `length`
	Index_Not_Integer,
	Non_Null_Assertion, // `x!` on null or undefined
	Type_Assertion, // an `as` that narrows a union fails its tag check
	Out_Of_Memory,
	Internal, // an assertion inside the runtime
	Exit_Code_Not_Integer, // process.exit with NaN, an infinity or a fraction: Node's RangeError
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
