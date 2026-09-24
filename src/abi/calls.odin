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
// maps each to one LLVM type, a Tagged parameter to two words and a Tagged result to a leading
// slot. A boolean is b64 here, the width the package uses for a boolean slot, so no export depends
// on how a C compiler widens a narrower one.
C_Type :: enum u8 {
	Void,
	Ptr,
	Number, // f64
	Boolean, // b64, 0 or 1
	// A Tagged travels as two word parameters, the tag and then the payload's bits. A 16-byte
	// struct does not travel alike everywhere: Win64 passes a pointer to a copy, SysV and arm64 two
	// registers. For the same reason a Tagged result comes back through the caller's slot: codegen
	// passes the address of a Tagged on its stack ahead of the other parameters, the export writes
	// it and returns nothing. That is Win64's hidden pointer, spelled out on every target.
	Tagged,
	// Any number of Tagged values, as the last parameter only and never as a result. They travel
	// as two parameters: the address of an array of Tagged on the caller's stack, nil when there
	// are none, and their count as an i64.
	Rest,
	// A Type_Table_ID widened to 64 bits, as a boolean is b64. Only codegen passes one, from the
	// layout of the instruction it emits; no IR value has this type.
	Table,
}

// Runtime_Proc lists the procedures the runtime exports to generated code. Runtime tasks add rows
// as they add exports.
Runtime_Proc :: enum u8 {
	// Console output, requirements 3.9. One call per statement: the runtime formats the whole line,
	// since a format string in the first argument decides how the others print, and writes it
	// once.
	Console_Log, // (err, args: Rest): console.log, or console.error when err is true
	Log_String, // (text: ^String_Cell): the units as UTF-8 and a newline to stdout
	Process_Argv, // () -> ^Array_Cell of strings: a new process.argv; lower calls it once
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
	// (text, index) -> ^String_Cell: the code point for...of reads at index, a surrogate pair or one
	// unit, with the index checked first
	String_Code_Point_At,
	String_Char_Code_At, // (text, position) -> f64
	String_Slice, // (text, start, end) -> ^String_Cell
	String_Index_Of, // (text, search, position) -> f64; includes is Index_Of != -1
	String_Starts_With, // (text, search, position) -> b64
	String_Ends_With, // (text, search, end) -> b64
	String_Trim, // (text) -> ^String_Cell
	String_To_Upper, // (text) -> ^String_Cell
	String_To_Lower, // (text) -> ^String_Cell
	String_Split, // (text, separator, limit) -> ^Array_Cell of strings
	// Numbers as strings, requirements 3.1.
	Number_To_String, // (value) -> ^String_Cell: String(value) and `${value}`
	Number_To_Fixed, // (value, digits) -> ^String_Cell; fails outside [0, 100] digits
	Number_Parse_Float, // (text) -> f64
	// Tagged values, requirements 3.4 and 3.7: the operations that dispatch on the tag at run time.
	Value_Typeof, // (value: Tagged) -> ^String_Cell: a static word
	Value_Equal, // (a, b: Tagged) -> b64: `===`
	Value_To_Boolean, // (value) -> b64: truthiness
	Value_To_String, // (value) -> ^String_Cell: String(value), `${value}`; fails on a function
	// Arrays, requirements 3.6 and the Array methods of 2.2 that lower does not inline. An element
	// goes in as a Tagged whatever the array holds; lower boxes it, which costs nothing for a number
	// or a reference.
	Array_Push, // (array, value: Tagged) -> f64: the new length; lower calls it once per item
	Array_Pop, // (array) -> Tagged: the last element, or undefined
	Array_Index_Of, // (array, search: Tagged, from) -> f64: `===`, so NaN is never found
	Array_Includes, // (array, search: Tagged, from) -> b64: SameValueZero, so NaN finds NaN
	Array_Slice, // (array, start, end) -> ^Array_Cell: always a new array
	Array_Join, // (array, separator) -> ^String_Cell; fails on a function, as Value_To_String does
	Array_Sort, // (array, compare: ^Closure_Cell) -> the array
	Array_Sort_Default, // (array) -> the array, in the order of its strings; fails as Array_Join does
	// Cells generated code fills itself: codegen calls these for ir.Alloc and ir.New_Array.
	Alloc, // (table) -> ^Cell_Header: a zero-filled cell of the table's size
	Array_New, // (table, length) -> ^Array_Cell: `length` elements, each the zero of its kind
	Fail, // (site: ^Fail_Site): a message to stderr, then exit code 1
}

Runtime_Export :: struct {
	symbol:   string,
	params:   []C_Type,
	result:   C_Type,
	// The export never returns: the runtime declares it `-> !`, codegen declares it noreturn.
	diverges: bool,
}

// The numbers the specification treats exactly as `undefined` where a call leaves an argument out.
// Lower passes the same number for an `undefined` known only at run time. Never NaN: slice(0, NaN)
// is "", while slice(0) is the whole string.
MISSING_END :: 0h7ff0_0000_0000_0000 // +Infinity
MISSING_LIMIT :: 4294967295 // 2^32 - 1, split's limit

// RUNTIME_EXPORTS gives each runtime export its symbol and C signature. The runtime names its
// exports from it (`link_name`) and codegen declares them from the same rows.
// Every symbol starts with `tsnc_` to stay clear of libc and Odin.
RUNTIME_EXPORTS :: [Runtime_Proc]Runtime_Export {
	.Console_Log = {symbol = "tsnc_console_log", params = {.Boolean, .Rest}, result = .Void},
	.Log_String = {symbol = "tsnc_log_string", params = {.Ptr}, result = .Void},
	.Process_Argv = {symbol = "tsnc_process_argv", params = {}, result = .Ptr},
	.Process_Exit = {
		symbol = "tsnc_process_exit",
		params = {.Number},
		result = .Void,
		diverges = true,
	},
	.Math_Round = {symbol = "tsnc_math_round", params = {.Number}, result = .Number},
	.Math_Max = {symbol = "tsnc_math_max", params = {.Number, .Number}, result = .Number},
	.Math_Min = {symbol = "tsnc_math_min", params = {.Number, .Number}, result = .Number},
	// An argument TypeScript lets a call leave out arrives as MISSING_END for an end, MISSING_LIMIT
	// for a limit, and 0 for a start, a position or a digit count. A separator join was not given
	// is the string constant ",".
	.String_Concat = {symbol = "tsnc_string_concat", params = {.Ptr, .Ptr}, result = .Ptr},
	.String_Equal = {symbol = "tsnc_string_equal", params = {.Ptr, .Ptr}, result = .Boolean},
	.String_Less = {symbol = "tsnc_string_less", params = {.Ptr, .Ptr}, result = .Boolean},
	.String_At = {symbol = "tsnc_string_at", params = {.Ptr, .Number}, result = .Ptr},
	.String_Code_Point_At = {
		symbol = "tsnc_string_code_point_at",
		params = {.Ptr, .Number},
		result = .Ptr,
	},
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
	.String_Split = {symbol = "tsnc_string_split", params = {.Ptr, .Ptr, .Number}, result = .Ptr},
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
	.Array_Push = {symbol = "tsnc_array_push", params = {.Ptr, .Tagged}, result = .Number},
	.Array_Pop = {symbol = "tsnc_array_pop", params = {.Ptr}, result = .Tagged},
	.Array_Index_Of = {
		symbol = "tsnc_array_index_of",
		params = {.Ptr, .Tagged, .Number},
		result = .Number,
	},
	.Array_Includes = {
		symbol = "tsnc_array_includes",
		params = {.Ptr, .Tagged, .Number},
		result = .Boolean,
	},
	.Array_Slice = {symbol = "tsnc_array_slice", params = {.Ptr, .Number, .Number}, result = .Ptr},
	.Array_Join = {symbol = "tsnc_array_join", params = {.Ptr, .Ptr}, result = .Ptr},
	.Array_Sort = {symbol = "tsnc_array_sort", params = {.Ptr, .Ptr}, result = .Ptr},
	.Array_Sort_Default = {symbol = "tsnc_array_sort_default", params = {.Ptr}, result = .Ptr},
	.Alloc = {symbol = "tsnc_alloc", params = {.Table}, result = .Ptr},
	.Array_New = {symbol = "tsnc_array_new", params = {.Table, .Number}, result = .Ptr},
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
	Invalid_String_Length, // a string past str.MAX_LENGTH units: Node's RangeError
	// %d of an object with its own valueOf or toString, which Node would call.
	Not_Convertible_To_Number,
	// %j of an object with its own toJSON, which Node would call.
	Not_Convertible_To_Json,
	Reduce_Of_Empty_Array, // reduce with no initial value on an empty array: Node's TypeError
	// A field read through its declared type holds a value of another kind, which a write through a
	// wider type of the same object put there (requirements 3.8).
	Field_Holds_Other_Kind,
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
