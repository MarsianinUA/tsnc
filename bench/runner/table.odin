package main

import "core:fmt"
import "core:strings"

// Table prints a Markdown table that lines up in a terminal too: the first column to the left, the
// others to the right, as `---:` aligns them when rendered. Rows print as they are measured, so the
// widths are fixed up front, and a longer cell pushes the rest of its row to the right.
Table :: struct {
	widths: []int,
}

// start_table prints the header; a column is as wide as its header, or as `least` asks.
start_table :: proc(headers: []string, least: []int = nil) -> (table: Table) {
	table.widths = make([]int, len(headers), context.temp_allocator)
	rule := make([]string, len(headers), context.temp_allocator)
	for header, i in headers {
		table.widths[i] = strings.rune_count(header)
		if i < len(least) {
			table.widths[i] = max(table.widths[i], least[i])
		}
		dashes := strings.repeat("-", table.widths[i], context.temp_allocator)
		rule[i] = dashes if i == 0 else fmt.tprintf("%s:", dashes[1:])
	}
	print_row(table, headers)
	print_row(table, rule)
	return table
}

print_row :: proc(table: Table, cells: []string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '|')
	for cell, i in cells {
		width := max(table.widths[i] - strings.rune_count(cell), 0)
		padding := strings.repeat(" ", width, context.temp_allocator)
		strings.write_byte(&b, ' ')
		if i > 0 {
			strings.write_string(&b, padding)
		}
		strings.write_string(&b, cell)
		if i == 0 {
			strings.write_string(&b, padding)
		}
		strings.write_string(&b, " |")
	}
	fmt.println(strings.to_string(b))
}

// print_table prints a table whose rows are all known, each column as wide as its longest cell.
print_table :: proc(headers: []string, rows: [][]string) {
	least := make([]int, len(headers), context.temp_allocator)
	for row in rows {
		for cell, i in row {
			least[i] = max(least[i], strings.rune_count(cell))
		}
	}
	table := start_table(headers, least)
	for row in rows {
		print_row(table, row)
	}
}
