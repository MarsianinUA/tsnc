package console

import "core:math"
import "core:unicode/utf16"

import "../../abi"
import "../gc"
import "../num"
import "../str"
import "../value"

/*
util.inspect of Node 24 (lib/internal/util/inspect.js) for the values a v1 program has, with the
options console.log passes: formatValue, formatRaw, formatProperty, groupArrayElements and
reduceToSingleString keep their names here, so the two read side by side. What v1 cannot build is
left out: symbols, classes, Maps and Sets, getters, proxies, sparse arrays.

An object is a plain object literal: its constructor is Object, and its own properties are the
fields of its type table in table order, an absent optional field left out. A function prints its
Function_Info. Under %o (show_hidden), an array also shows its length, and a function its length,
name and prototype, whose constructor is the function itself.

Every piece is UTF-16 units in context.allocator. A formatted value is appended to a [dynamic]u16,
and an object or an array first builds one such text per entry, since the entries decide whether
it fits on one line.
*/

Inspect_Options :: struct {
	depth:       int, // the levels of arrays and objects that print before [Array] and [Object]
	colors:      bool,
	show_hidden: bool,
}

// The options console.log leaves at their defaults.
@(private)
BREAK_LENGTH :: 80
@(private)
COMPACT :: 3
@(private)
MAX_ARRAY_LENGTH :: 100
@(private)
MAX_STRING_LENGTH :: 10000
// kMinLineLength: a shorter string never splits at its line breaks.
@(private)
MIN_LINE_LENGTH :: 16
// Past this many units of output at one indentation, everything deeper prints as [Object], as in
// Node, so a huge value cannot fill the memory.
@(private)
BUDGET :: 1 << 27

@(private)
Extras :: enum u8 {
	Object, // kObjectType
	Array, // kArrayExtrasType
}

@(private)
Inspector :: struct {
	heap:          ^gc.Heap,
	colors:        bool,
	show_hidden:   bool,
	depth:         int, // the budget can lower it to -1
	indentation:   int,
	// The depth of the object entered last, not the deepest one: reduce_to_single_string reads it
	// right after the entries of an object were formatted.
	current_depth: int,
	seen:          [dynamic]^abi.Cell_Header, // the objects being formatted, outermost first
	circular:      [dynamic]^abi.Cell_Header, // a cell's reference number is its index plus one
	budget:        [dynamic]int, // by indentation
}

inspect :: proc(heap: ^gc.Heap, v: abi.Tagged, options: Inspect_Options, units: ^[dynamic]u16) {
	ins := Inspector {
		heap        = heap,
		colors      = options.colors,
		show_hidden = options.show_hidden,
		depth       = options.depth,
	}
	format_value(&ins, v, 0, units)
}

@(private)
format_value :: proc(ins: ^Inspector, v: abi.Tagged, recurse_times: int, out: ^[dynamic]u16) {
	switch v.tag {
	case .Undefined:
		styled(ins.colors, out, "undefined", .Undefined)
	case .Null:
		styled(ins.colors, out, "null", .Null)
	case .Boolean:
		styled(ins.colors, out, "true" if v.payload.boolean else "false", .Boolean)
	case .Number:
		format_number(ins.colors, v.payload.number, out)
	case .String:
		format_string(ins, str.units((^abi.String_Cell)(v.payload.ref)), out)
	case .Object, .Function:
		cell := v.payload.ref
		for seen in ins.seen {
			if seen == cell {
				open_style(ins.colors, out, .Special)
				append_ascii(out, "[Circular *")
				append_int(out, reference_number(ins, cell))
				append(out, ']')
				close_style(ins.colors, out, .Special)
				return
			}
		}
		format_raw(ins, cell, recurse_times, out)
	}
}

// reference_number gives a cell the next number the first time it closes a cycle.
@(private)
reference_number :: proc(ins: ^Inspector, cell: ^abi.Cell_Header) -> int {
	for known, i in ins.circular {
		if known == cell {
			return i + 1
		}
	}
	append(&ins.circular, cell)
	return len(ins.circular)
}

@(private)
format_raw :: proc(
	ins: ^Inspector,
	cell: ^abi.Cell_Header,
	recurse_times: int,
	out: ^[dynamic]u16,
) {
	table := gc.table_of(ins.heap, cell)
	// What stands before the braces: [Function: name] for a function, and <ref *n> in front of
	// anything a cycle leads back to.
	base: [dynamic]u16
	#partial switch table.kind {
	case .Array:
		if (^abi.Array_Cell)(cell).length == 0 && !ins.show_hidden {
			append_ascii(out, "[]")
			return
		}
	case .Object:
		if !has_fields(ins.heap, cell, table) {
			append_ascii(out, "{}")
			return
		}
	case .Closure:
		function_base(&base, (^abi.Closure_Cell)(cell).info)
		if !ins.show_hidden {
			open_style(ins.colors, out, .Special)
			append(out, ..base[:])
			close_style(ins.colors, out, .Special)
			return
		}
	case:
		panic("a tagged reference to a cell that is no value")
	}

	if recurse_times > ins.depth {
		open_style(ins.colors, out, .Special)
		#partial switch table.kind {
		case .Array:
			append_ascii(out, "[Array]")
		case .Object:
			append_ascii(out, "[Object]")
		case:
			append_ascii(out, "[Function]")
		}
		close_style(ins.colors, out, .Special)
		return
	}
	inner := recurse_times + 1
	append(&ins.seen, cell)
	ins.current_depth = inner

	entries := make([dynamic][]u16)
	extras := Extras.Object
	array: ^abi.Array_Cell
	#partial switch table.kind {
	case .Array:
		array = (^abi.Array_Cell)(cell)
		extras = .Array
		format_array(ins, array, table.element, inner, &entries)
		if ins.show_hidden {
			entry := make([dynamic]u16)
			append_ascii(&entry, "[length]: ")
			format_number(ins.colors, f64(array.length), &entry)
			append(&entries, entry[:])
		}
	case .Object:
		format_fields(ins, cell, table, inner, &entries)
	case .Closure:
		format_function_properties(ins, (^abi.Closure_Cell)(cell), inner, &entries)
	}

	for known, i in ins.circular {
		if known == cell {
			reference := make([dynamic]u16)
			open_style(ins.colors, &reference, .Special)
			append_ascii(&reference, "<ref *")
			append_int(&reference, i + 1)
			append(&reference, '>')
			close_style(ins.colors, &reference, .Special)
			if len(base) > 0 {
				append(&reference, ' ')
				append(&reference, ..base[:])
			}
			base = reference
			break
		}
	}
	pop(&ins.seen)

	braces := [2]string{"[", "]"} if extras == .Array else [2]string{"{", "}"}
	start := len(out)
	reduce_to_single_string(ins, entries[:], base[:], braces, extras, inner, array, out)
	spend_budget(ins, len(out) - start)
}

// spend_budget is Node's guard against a result past what a string can hold: once one indentation
// has produced BUDGET units, nothing deeper is inspected.
@(private)
spend_budget :: proc(ins: ^Inspector, length: int) {
	for len(ins.budget) <= ins.indentation {
		append(&ins.budget, 0)
	}
	ins.budget[ins.indentation] += length
	if ins.budget[ins.indentation] > BUDGET {
		ins.depth = -1
	}
}

// format_array is formatArray: the first MAX_ARRAY_LENGTH elements, then how many more there are.
@(private)
format_array :: proc(
	ins: ^Inspector,
	array: ^abi.Array_Cell,
	kind: abi.Slot_Kind,
	recurse_times: int,
	entries: ^[dynamic][]u16,
) {
	shown := min(array.length, MAX_ARRAY_LENGTH)
	size := abi.SLOT_SIZE[kind]
	for i in 0 ..< shown {
		element := value.load(ins.heap, &([^]byte)(array.elements)[i * size], kind)
		entry := make([dynamic]u16)
		ins.indentation += 2
		format_value(ins, element, recurse_times, &entry)
		ins.indentation -= 2
		append(entries, entry[:])
	}
	if remaining := array.length - shown; remaining > 0 {
		entry := make([dynamic]u16)
		append_ascii(&entry, "... ")
		append_int(&entry, remaining)
		append_ascii(&entry, " more items" if remaining > 1 else " more item")
		append(entries, entry[:])
	}
}

// format_fields is formatProperty over the own properties of an object.
@(private)
format_fields :: proc(
	ins: ^Inspector,
	cell: ^abi.Cell_Header,
	table: abi.Type_Table,
	recurse_times: int,
	entries: ^[dynamic][]u16,
) {
	for field in table.fields {
		v, present := value.field(ins.heap, cell, field)
		if !present {
			continue
		}
		entry := make([dynamic]u16)
		format_key(ins.colors, field.name, &entry)
		append_ascii(&entry, ": ")
		ins.indentation += 2
		format_value(ins, v, recurse_times, &entry)
		ins.indentation -= 2
		append(entries, entry[:])
	}
}

// format_key writes a key the way formatProperty names it: an identifier as it is, anything else
// as a quoted string.
@(private)
format_key :: proc(colors: bool, name: string, out: ^[dynamic]u16) {
	if is_identifier(name) {
		append_ascii(out, "['__proto__']" if name == "__proto__" else name)
		return
	}
	units := make([]u16, len(name))
	open_style(colors, out, .String)
	str_escape(string16(units[:utf16.encode_string(units, name)]), out)
	close_style(colors, out, .String)
}

// is_identifier is keyStrRegExp, /^[a-zA-Z_][a-zA-Z_0-9]*$/, which leaves out `$` and every
// letter past ASCII.
@(private)
is_identifier :: proc(name: string) -> bool {
	if len(name) == 0 {
		return false
	}
	for i in 0 ..< len(name) {
		c := name[i]
		letter := 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || c == '_'
		if !letter && !(i > 0 && '0' <= c && c <= '9') {
			return false
		}
	}
	return true
}

// format_function_properties is what %o shows of a function: its own length, name and, unless it
// is an arrow, prototype. They are not enumerable, so each name is in brackets.
@(private)
format_function_properties :: proc(
	ins: ^Inspector,
	closure: ^abi.Closure_Cell,
	recurse_times: int,
	entries: ^[dynamic][]u16,
) {
	length := closure.info.length if closure.info != nil else 0
	length_entry := make([dynamic]u16)
	append_ascii(&length_entry, "[length]: ")
	format_number(ins.colors, f64(length), &length_entry)
	append(entries, length_entry[:])

	name_entry := make([dynamic]u16)
	append_ascii(&name_entry, "[name]: ")
	ins.indentation += 2
	format_string(ins, function_name(closure.info), &name_entry)
	ins.indentation -= 2
	append(entries, name_entry[:])

	if closure.info != nil && closure.info.has_prototype {
		prototype_entry := make([dynamic]u16)
		append_ascii(&prototype_entry, "[prototype]: ")
		ins.indentation += 2
		format_prototype(ins, closure, recurse_times, &prototype_entry)
		ins.indentation -= 2
		append(entries, prototype_entry[:])
	}
}

// format_prototype is formatRaw of a function's prototype object, which has no cell: its one own
// property is `constructor`, the function, which is being formatted and so prints as a cycle.
@(private)
format_prototype :: proc(
	ins: ^Inspector,
	closure: ^abi.Closure_Cell,
	recurse_times: int,
	out: ^[dynamic]u16,
) {
	if recurse_times > ins.depth {
		styled(ins.colors, out, "[Object]", .Special)
		return
	}
	inner := recurse_times + 1
	ins.current_depth = inner
	entry := make([dynamic]u16)
	append_ascii(&entry, "[constructor]: ")
	ins.indentation += 2
	format_value(ins, {tag = .Function, payload = {ref = closure}}, inner, &entry)
	ins.indentation -= 2
	entries := [?][]u16{entry[:]}
	start := len(out)
	reduce_to_single_string(ins, entries[:], nil, {"{", "}"}, .Object, inner, nil, out)
	spend_budget(ins, len(out) - start)
}

// function_base is getFunctionBase of a plain function: [Function: name], or (anonymous).
@(private)
function_base :: proc(out: ^[dynamic]u16, info: ^abi.Function_Info) {
	name := function_name(info)
	if len(name) == 0 {
		append_ascii(out, "[Function (anonymous)]")
		return
	}
	append_ascii(out, "[Function: ")
	append_units(out, name)
	append(out, ']')
}

@(private)
function_name :: proc(info: ^abi.Function_Info) -> string16 {
	if info == nil || info.name == nil {
		return ""
	}
	return str.units(info.name)
}

// reduce_to_single_string puts the entries on one line when they fit in BREAK_LENGTH and nothing
// they hold is deeper than COMPACT levels, and one entry per line otherwise. An array of more than
// six entries is first grouped into columns.
@(private)
reduce_to_single_string :: proc(
	ins: ^Inspector,
	entries: [][]u16,
	base: []u16,
	braces: [2]string,
	extras: Extras,
	recurse_times: int,
	array: ^abi.Array_Cell,
	out: ^[dynamic]u16,
) {
	output := entries
	if extras == .Array && len(entries) > 6 {
		output = group_array_elements(ins, entries, array)
	}
	if ins.current_depth - recurse_times < COMPACT && len(entries) == len(output) {
		start := len(output) + ins.indentation + len(braces[0]) + len(base) + 10
		if is_below_break_length(ins, output, start, base) && !has_line_break(output) {
			if len(base) > 0 {
				append(out, ..base)
				append(out, ' ')
			}
			append_ascii(out, braces[0])
			append(out, ' ')
			join(out, output, ", ", 0)
			append(out, ' ')
			append_ascii(out, braces[1])
			return
		}
	}
	if len(base) > 0 {
		append(out, ..base)
		append(out, ' ')
	}
	append_ascii(out, braces[0])
	new_line(out, ins.indentation + 2)
	join(out, output, ",", ins.indentation + 2)
	new_line(out, ins.indentation)
	append_ascii(out, braces[1])
}

// join writes the entries with `separator` between them and, when `indentation` is not 0, a new
// line indented that far after it.
@(private)
join :: proc(out: ^[dynamic]u16, entries: [][]u16, separator: string, indentation: int) {
	for entry, i in entries {
		if i > 0 {
			append_ascii(out, separator)
			if indentation > 0 {
				new_line(out, indentation)
			}
		}
		append(out, ..entry)
	}
}

@(private)
new_line :: proc(out: ^[dynamic]u16, indentation: int) {
	append(out, '\n')
	for _ in 0 ..< indentation {
		append(out, ' ')
	}
}

@(private)
has_line_break :: proc(entries: [][]u16) -> bool {
	for entry in entries {
		for unit in entry {
			if unit == '\n' {
				return true
			}
		}
	}
	return false
}

// is_below_break_length counts units, not columns, as Node does, and leaves out the color codes.
@(private)
is_below_break_length :: proc(ins: ^Inspector, output: [][]u16, start: int, base: []u16) -> bool {
	total := len(output) + start
	if total + len(output) > BREAK_LENGTH {
		return false
	}
	for entry in output {
		total += visible_length(entry) if ins.colors else len(entry)
		if total > BREAK_LENGTH {
			return false
		}
	}
	for unit in base {
		if unit == '\n' {
			return false
		}
	}
	return true
}

// visible_length is the length of removeColors(text): less every ESC [ d m and ESC [ d d m.
@(private)
visible_length :: proc(text: []u16) -> int {
	length := len(text)
	for i := 0; i + 3 < len(text); i += 1 {
		if text[i] != 0x1b || text[i + 1] != '[' || !is_digit(text[i + 2]) {
			continue
		}
		switch {
		case text[i + 3] == 'm':
			length -= 4
		case is_digit(text[i + 3]) && i + 4 < len(text) && text[i + 4] == 'm':
			length -= 5
		}
	}
	return length
}

@(private)
is_digit :: proc(unit: u16) -> bool {
	return '0' <= unit && unit <= '9'
}

// group_array_elements is groupArrayElements: entries short enough, and alike enough, go into
// columns, as many as make the result roughly square. Numbers line up on the right, anything else
// on the left. A "... more items" entry stays on a line of its own.
@(private)
group_array_elements :: proc(ins: ^Inspector, output: [][]u16, array: ^abi.Array_Cell) -> [][]u16 {
	SEPARATOR_SPACE :: 2 // a comma and a space
	total_length := 0
	max_length := 0
	output_length := len(output)
	if MAX_ARRAY_LENGTH < len(output) {
		output_length -= 1
	}
	data_len := make([]int, output_length)
	for i in 0 ..< output_length {
		width := string_width(string16(output[i]))
		data_len[i] = width
		total_length += width + SEPARATOR_SPACE
		max_length = max(max_length, width)
	}
	actual_max := max_length + SEPARATOR_SPACE
	spread := f64(total_length) / f64(actual_max) > 5 || max_length <= 6
	if actual_max * 3 + ins.indentation >= BREAK_LENGTH || !spread {
		return output
	}

	average_bias := math.sqrt(f64(actual_max) - f64(total_length) / f64(len(output)))
	biased_max := math.max(f64(actual_max) - 3 - average_bias, 1)
	square := int(num.round(math.sqrt(2.5 * biased_max * f64(output_length)) / biased_max))
	columns := min(square, (BREAK_LENGTH - ins.indentation) / actual_max, COMPACT * 4, 15)
	if columns <= 1 {
		return output
	}
	max_line_length := make([]int, columns)
	for i in 0 ..< columns {
		line_max := 0
		for j := i; j < output_length; j += columns {
			line_max = max(line_max, data_len[j])
		}
		max_line_length[i] = line_max + SEPARATOR_SPACE
	}
	// Node looks at value[i] for every entry, the "more items" one and %o's [length] included, and
	// past the end of the array that is undefined.
	pad_start := len(output) <= array.length
	kind := gc.table_of(ins.heap, array).element
	for i := 0; pad_start && i < len(output); i += 1 {
		slot := &([^]byte)(array.elements)[i * abi.SLOT_SIZE[kind]]
		pad_start = value.load(ins.heap, slot, kind).tag == .Number
	}

	grouped := make([dynamic][]u16)
	for i := 0; i < output_length; i += columns {
		last := min(i + columns, output_length)
		line := make([dynamic]u16)
		j := i
		for ; j < last - 1; j += 1 {
			padding := max_line_length[j - i] + len(output[j]) - data_len[j]
			pad(&line, output[j], ", ", padding, pad_start)
		}
		if pad_start {
			padding := max_line_length[j - i] + len(output[j]) - data_len[j] - SEPARATOR_SPACE
			pad(&line, output[j], "", padding, true)
		} else {
			append(&line, ..output[j])
		}
		append(&grouped, line[:])
	}
	if MAX_ARRAY_LENGTH < len(output) {
		append(&grouped, output[output_length])
	}
	return grouped[:]
}

// pad is padStart or padEnd of `text` and `tail` together, to `width` units.
@(private)
pad :: proc(out: ^[dynamic]u16, text: []u16, tail: string, width: int, at_start: bool) {
	spaces := width - len(text) - len(tail)
	if at_start {
		for _ in 0 ..< spaces {
			append(out, ' ')
		}
	}
	append(out, ..text)
	append_ascii(out, tail)
	if !at_start {
		for _ in 0 ..< spaces {
			append(out, ' ')
		}
	}
}

// format_number is formatNumber: the digits of Number::toString, and -0 with its sign.
@(private)
format_number :: proc(colors: bool, n: f64, out: ^[dynamic]u16) {
	buf: [num.STRING_MAX]byte
	styled(colors, out, number_text(buf[:], n), .Number)
}

// format_string is formatPrimitive of a string: quoted and escaped, cut after MAX_STRING_LENGTH
// units, and, when it is long, split after each line break into pieces joined by +.
@(private)
format_string :: proc(ins: ^Inspector, text: string16, out: ^[dynamic]u16) {
	shown := text
	remaining := 0
	if len(text) > MAX_STRING_LENGTH {
		remaining = len(text) - MAX_STRING_LENGTH
		shown = text[:MAX_STRING_LENGTH]
	}
	if len(shown) > MIN_LINE_LENGTH && len(shown) > BREAK_LENGTH - ins.indentation - 4 {
		start := 0
		for i in 0 ..< len(shown) {
			if shown[i] != '\n' || i + 1 == len(shown) {
				continue
			}
			quoted_piece(ins.colors, shown[start:i + 1], out)
			append_ascii(out, " +")
			new_line(out, ins.indentation + 2)
			start = i + 1
		}
		quoted_piece(ins.colors, shown[start:], out)
	} else {
		quoted_piece(ins.colors, shown, out)
	}
	if remaining > 0 {
		append_ascii(out, "... ")
		append_int(out, remaining)
		append_ascii(out, " more characters" if remaining > 1 else " more character")
	}
}

@(private)
quoted_piece :: proc(colors: bool, text: string16, out: ^[dynamic]u16) {
	open_style(colors, out, .String)
	str_escape(text, out)
	close_style(colors, out, .String)
}

// str_escape is strEscape: the text in single quotes, or in double quotes or backticks when that
// saves escaping a single quote, with the control characters, the backslash, the quote and every
// unpaired surrogate escaped.
@(private)
str_escape :: proc(text: string16, out: ^[dynamic]u16) {
	quote := u16('\'')
	if contains_unit(text, '\'') {
		if !contains_unit(text, '"') {
			quote = '"'
		} else if !contains_unit(text, '`') && !contains_template_start(text) {
			quote = '`'
		}
	}
	append(out, quote)
	for i := 0; i < len(text); i += 1 {
		unit := text[i]
		switch {
		case unit == quote && quote == '\'':
			append_ascii(out, "\\'")
		case unit == '\\':
			append_ascii(out, "\\\\")
		case unit < 0x20 || 0x7e < unit && unit < 0xa0:
			append_meta(out, unit)
		case is_pair(text, i):
			append(out, unit, text[i + 1])
			i += 1
		case 0xd800 <= unit && unit <= 0xdfff:
			append_ascii(out, "\\u")
			append_hex(out, unit)
		case:
			append(out, unit)
		}
	}
	append(out, quote)
}

// append_meta writes a control character the way util.inspect's meta table spells it: the five
// with a letter as \b \t \n \f \r, the rest as \x and two uppercase digits.
@(private)
append_meta :: proc(out: ^[dynamic]u16, unit: u16) {
	switch unit {
	case '\b':
		append_ascii(out, "\\b")
	case '\t':
		append_ascii(out, "\\t")
	case '\n':
		append_ascii(out, "\\n")
	case '\f':
		append_ascii(out, "\\f")
	case '\r':
		append_ascii(out, "\\r")
	case:
		digits := "0123456789ABCDEF"
		append_ascii(out, "\\x")
		append(out, u16(digits[unit >> 4]), u16(digits[unit & 0xf]))
	}
}

// is_pair answers whether a high surrogate at `i` has its low one after it.
@(private)
is_pair :: proc(text: string16, i: int) -> bool {
	high := 0xd800 <= text[i] && text[i] <= 0xdbff
	return high && i + 1 < len(text) && 0xdc00 <= text[i + 1] && text[i + 1] <= 0xdfff
}

@(private)
contains_unit :: proc(text: string16, unit: u16) -> bool {
	for u in transmute([]u16)text {
		if u == unit {
			return true
		}
	}
	return false
}

@(private)
contains_template_start :: proc(text: string16) -> bool {
	for i in 0 ..< len(text) - 1 {
		if text[i] == '$' && text[i + 1] == '{' {
			return true
		}
	}
	return false
}

@(private)
has_fields :: proc(heap: ^gc.Heap, cell: ^abi.Cell_Header, table: abi.Type_Table) -> bool {
	for field in table.fields {
		if _, present := value.field(heap, cell, field); present {
			return true
		}
	}
	return false
}

@(private)
append_ascii :: proc(out: ^[dynamic]u16, text: string) {
	for i in 0 ..< len(text) {
		append(out, u16(text[i]))
	}
}

@(private)
append_units :: proc(out: ^[dynamic]u16, text: string16) {
	append(out, ..transmute([]u16)text)
}

@(private)
append_int :: proc(out: ^[dynamic]u16, n: int) {
	digits: [20]u16
	at := len(digits)
	for rest := n;; rest /= 10 {
		at -= 1
		digits[at] = u16('0' + rest % 10)
		if rest < 10 {
			break
		}
	}
	append(out, ..digits[at:])
}

// append_hex writes the lowercase digits of `unit` without leading zeros.
@(private)
append_hex :: proc(out: ^[dynamic]u16, unit: u16) {
	digits: [4]u16
	at := len(digits)
	for rest := unit;; rest >>= 4 {
		at -= 1
		digit := rest & 0xf
		digits[at] = '0' + digit if digit < 10 else 'a' + digit - 10
		if rest < 16 {
			break
		}
	}
	append(out, ..digits[at:])
}
