package console_tests

import "core:testing"

import "../../../src/runtime/console"

// Every code point on its own against Node, whose getStringWidth is internal:
//
//	node --expose-internals -e "const {getStringWidth} = require('internal/util/inspect'); let h = 0x811c9dc5, n = 0; for (let c = 0; c <= 0x10ffff; c++) { const w = getStringWidth(String.fromCodePoint(c)); n += w; h = Math.imul(h ^ w, 0x01000193) >>> 0 } console.log(h.toString(16), n)"
//
// A surrogate code point is a lone unit, as String.fromCodePoint makes it.
@(test)
every_code_point_has_the_width_node_gives_it :: proc(t: ^testing.T) {
	hash := u32(0x811c9dc5)
	total := 0
	for code in rune(0) ..= 0x10ffff {
		units: [2]u16
		count := 1
		if code > 0xffff {
			units[0] = u16(0xd800 + (code - 0x10000) >> 10)
			units[1] = u16(0xdc00 + (code - 0x10000) & 0x3ff)
			count = 2
		} else {
			units[0] = u16(code)
		}
		width := console.string_width(string16(units[:count]))
		total += width
		hash = (hash ~ u32(width)) * 0x01000193
	}
	testing.expectf(t, hash == 0x92ec45f6, "hash %x", hash)
	testing.expect_value(t, total, 1294737)
}

// node --expose-internals -e "const {getStringWidth} = require('internal/util/inspect'); for (const s of ['\u4e2d\u6587', 'e\u0301', '\u{1F600}', 'a\x1b[33mb']) console.log(getStringWidth(s))"
@(test)
a_string_counts_its_columns :: proc(t: ^testing.T) {
	testing.expect_value(t, console.string_width("\u4e2d\u6587"), 4)
	testing.expect_value(t, console.string_width("e\u0301"), 1)
	testing.expect_value(t, console.string_width("\U0001F600"), 2)
	// The style colors put around a value takes no column.
	testing.expect_value(t, console.string_width("a\x1b[33mb\x1b[39m"), 2)
	// Node counts 2 after it composes the syllable; tsnc does not compose.
	testing.expect_value(t, console.string_width("\u1100\u1161"), 3)
}
