package console

/*
How many columns a terminal gives a text: Node's getStringWidth (lib/internal/util/inspect.js),
which lines up the columns of a grouped array. A code point takes the width WIDTH_RUNS gives it,
and 1 when it is in no run; width_tables.odin is generated from the Unicode Character Database,
and docs/development.md says how.

Node normalizes the text to NFC before it counts, and this does not. The table already gives a
code point the width of its own NFC form, which differs for the thirteen musical symbols that stay
decomposed, but a sequence can compose: U+1100 U+1161, a Hangul syllable written as two jamo, is 2
columns in Node and 3 here, and so are the Indic vowels written in two parts.
*/

Width_Run :: struct {
	first, last: rune,
	width:       u8,
}

// string_width skips the escape sequences colors.odin writes, ESC [ digits m, as Node skips them
// when it colors. A lone surrogate is a code point of its own, 1 column wide.
string_width :: proc(text: string16) -> int {
	width := 0
	for i := 0; i < len(text); i += 1 {
		unit := text[i]
		switch {
		case unit == 0x1b && i + 1 < len(text) && text[i + 1] == '[':
			for i < len(text) && text[i] != 'm' {
				i += 1
			}
		case unit < 0x7f:
			if unit >= 0x20 {
				width += 1
			}
		case is_pair(text, i):
			high, low := rune(unit) - 0xd800, rune(text[i + 1]) - 0xdc00
			width += column_width(0x10000 + high << 10 + low)
			i += 1
		case:
			width += column_width(rune(unit))
		}
	}
	return width
}

@(private)
column_width :: proc "contextless" (r: rune) -> int {
	low, high := 0, len(WIDTH_RUNS)
	for low < high {
		middle := (low + high) / 2
		run := WIDTH_RUNS[middle]
		switch {
		case r < run.first:
			high = middle
		case r > run.last:
			low = middle + 1
		case:
			return int(run.width)
		}
	}
	return 1
}
