package rt

import "base:runtime"
import "core:c"

// UCRT parses the wide command line for wmain, which is how Node reads its arguments on Windows;
// os.args is the narrow argv, in the ANSI code page. libcmt, which the Windows link flags name,
// brings the symbols in.
foreign _ {
	_configure_wide_argv :: proc "c" (mode: c.int) -> c.int ---
	__p___argc :: proc "c" () -> ^c.int ---
	__p___wargv :: proc "c" () -> ^[^][^]u16 ---
}

// _crt_argv_unexpanded_arguments: every argument as the command line spells it, with no wildcard
// expanded, as wmainCRTStartup asks for by default.
@(private)
UNEXPANDED_ARGUMENTS :: 1

// wide_arguments copies the arguments into `allocator`. An unpaired surrogate becomes U+FFFD, as
// WideCharToMultiByte turns it when Node converts an argument to UTF-8.
@(private)
wide_arguments :: proc(allocator: runtime.Allocator) -> []string16 {
	ensure(_configure_wide_argv(UNEXPANDED_ARGUMENTS) == 0, "the wide command line cannot be read")
	count := int(__p___argc()^)
	wargv := __p___wargv()^
	arguments := make([]string16, count, allocator)
	for i in 0 ..< count {
		wide := wargv[i]
		length := 0
		for wide[length] != 0 {
			length += 1
		}
		units := make([]u16, length, allocator)
		for j := 0; j < length; j += 1 {
			unit := wide[j]
			switch {
			case unit < 0xd800 || unit > 0xdfff:
				units[j] = unit
			case unit < 0xdc00 && j + 1 < length && 0xdc00 <= wide[j + 1] && wide[j + 1] <= 0xdfff:
				units[j], units[j + 1] = unit, wide[j + 1]
				j += 1
			case:
				units[j] = 0xfffd
			}
		}
		arguments[i] = string16(units)
	}
	return arguments
}
