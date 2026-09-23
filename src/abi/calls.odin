package abi

// MAIN_SYMBOL names the generated entry point, proc "c" (). The runtime's main calls it once, after
// setting up the Odin context.
MAIN_SYMBOL :: "tsnc_main"

// TYPE_TABLES_SYMBOL names a proc "c" () -> ^[]Type_Table that the compiler emits: it answers the
// program's type tables, constant data in Type_Table_ID order after Builtin_Table. The runtime's
// main registers them with the heap before it calls MAIN_SYMBOL. A procedure and not the slice
// itself, because Odin declares a foreign variable dllimport on Windows, and lld-link then warns
// that a symbol of the program object is imported.
TYPE_TABLES_SYMBOL :: "tsnc_type_tables"

// ROOTS_SYMBOL names a proc "c" () -> ^[]Root that the compiler emits. A procedure for the reason
// TYPE_TABLES_SYMBOL is one.
ROOTS_SYMBOL :: "tsnc_roots"

// C_Type is the type of a runtime export parameter or result in the C calling convention; codegen
// maps each to one LLVM type, a Tagged to two. A boolean is b64 here, the width the package uses
// for a boolean slot, so no export depends on how a C compiler widens a narrower one.
C_Type :: enum u8 {
	Void,
	Ptr,
	Number, // f64
	Boolean, // b64, 0 or 1
	// A Tagged travels as two word parameters, the tag and then the payload's bits. A 16-byte
	// struct does not travel alike everywhere: Win64 passes a pointer to a copy, SysV and arm64 two
	// registers. For the same reason no export returns one.
	Tagged,
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
	// Strings, requirements 3.2, and the String methods of 2.2. `length` has no row: generated code
	// loads String_Cell.length. A string result may be an argument or a static cell, never a
	// promised fresh one.
	String_Concat, // (a, b: ^String_Cell) -> ^String_Cell
	String_Equal, // (a, b) -> b64: `===`
	String_Less, // (a, b) -> b64: `a < b` by units; lower swaps and negates for `>`, `<=`, `>=`
	String_At, // (text, index) -> ^String_Cell: text[index], with the index checked first
	String_Char_Code_At, // (text, position) -> f64
	String_Slice, // (text, start, end) -> ^String_Cell
	String_Index_Of, // (text, search, position) -> f64; includes is Index_Of != -1
	String_Starts_With, // (text, search, position) -> b64
	String_Ends_With, // (text, search, end) -> b64
	String_Trim, // (text) -> ^String_Cell
	String_To_Upper, // (text) -> ^String_Cell
	String_To_Lower, // (text) -> ^String_Cell
	// Numbers as strings, requirements 3.1.
	Number_To_String, // (value) -> ^String_Cell: String(value) and `${value}`
	Number_To_Fixed, // (value, digits) -> ^String_Cell; fails outside [0, 100] digits
	Number_Parse_Float, // (text) -> f64
	// Tagged values, requirements 3.4 and 3.7: the operations that dispatch on the tag at run time.
	Value_Typeof, // (value: Tagged) -> ^String_Cell: a static word
	Value_Equal, // (a, b: Tagged) -> b64: `===`
	Value_To_Boolean, // (value) -> b64: truthiness
	Value_To_String, // (value) -> ^String_Cell: String(value), `${value}`; fails on a function
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
	// An argument TypeScript lets a call leave out still arrives, as the number the specification
	// treats exactly as `undefined` there: +Infinity for an end, 0 for a start, a position or a
	// digit count. Lower passes the same number for an `undefined` known only at run time. Never
	// NaN: slice(0, NaN) is "", while slice(0) is the whole string.
	.String_Concat = {symbol = "tsnc_string_concat", params = {.Ptr, .Ptr}, result = .Ptr},
	.String_Equal = {symbol = "tsnc_string_equal", params = {.Ptr, .Ptr}, result = .Boolean},
	.String_Less = {symbol = "tsnc_string_less", params = {.Ptr, .Ptr}, result = .Boolean},
	.String_At = {symbol = "tsnc_string_at", params = {.Ptr, .Number}, result = .Ptr},
	.String_Char_Code_At = {
		symbol = "tsnc_string_char_code_at",
		params = {.Ptr, .Number},
		result = .Number,
	},
	.String_Slice = {
		symbol = "tsnc_string_slice",
		params = {.Ptr, .Number, .Number},
		result = .Ptr,
	},
	.String_Index_Of = {
		symbol = "tsnc_string_index_of",
		params = {.Ptr, .Ptr, .Number},
		result = .Number,
	},
	.String_Starts_With = {
		symbol = "tsnc_string_starts_with",
		params = {.Ptr, .Ptr, .Number},
		result = .Boolean,
	},
	.String_Ends_With = {
		symbol = "tsnc_string_ends_with",
		params = {.Ptr, .Ptr, .Number},
		result = .Boolean,
	},
	.String_Trim = {symbol = "tsnc_string_trim", params = {.Ptr}, result = .Ptr},
	.String_To_Upper = {symbol = "tsnc_string_to_upper", params = {.Ptr}, result = .Ptr},
	.String_To_Lower = {symbol = "tsnc_string_to_lower", params = {.Ptr}, result = .Ptr},
	.Number_To_String = {symbol = "tsnc_number_to_string", params = {.Number}, result = .Ptr},
	.Number_To_Fixed = {
		symbol = "tsnc_number_to_fixed",
		params = {.Number, .Number},
		result = .Ptr,
	},
	.Number_Parse_Float = {symbol = "tsnc_number_parse_float", params = {.Ptr}, result = .Number},
	.Value_Typeof = {symbol = "tsnc_value_typeof", params = {.Tagged}, result = .Ptr},
	.Value_Equal = {symbol = "tsnc_value_equal", params = {.Tagged, .Tagged}, result = .Boolean},
	.Value_To_Boolean = {symbol = "tsnc_value_to_boolean", params = {.Tagged}, result = .Boolean},
	.Value_To_String = {symbol = "tsnc_value_to_string", params = {.Tagged}, result = .Ptr},
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
	Fraction_Digits_Out_Of_Range, // toFixed outside [0, 100] digits: Node's RangeError
	// Node prints a function's source text, which a compiled program does not keep, and calls an
	// object's own toString.
	Not_Convertible_To_String,
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
