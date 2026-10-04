package codegen_tests

import "core:strings"
import "core:testing"

/*
What codegen tells LLVM about memory, read back from the module text: the alias tag on each kind of
access and the attributes each abi.Effect gives a runtime declaration. A tag on the wrong kind of
place is a miscompile the corpora may not show.
*/

ALIAS_PROGRAM :: `interface Point {
  x: number;
  y: number;
  next: Point | null;
  label: number | string;
}
interface Circle {
  kind: "circle";
  r: number;
}
interface Square {
  kind: "square";
  side: number;
}
type Shape = Circle | Square;

const flags: boolean[] = [true, false];
const xs: number[] = [1, 2];
const names: string[] = ["a"];
let total = 0;

function area(s: Shape): number {
  return s.kind === "circle" ? s.r : s.side;
}

function run(p: Point, text: string, f: (n: number) => number): void {
  p.x = p.y + 1;
  p.next = p;
  p.label = "a";
  xs[0] = xs[1] * 2;
  flags[0] = !flags[1];
  names.push(text[0]);
  total += xs.length + text.length + names.join(",").length + f(1);
}

run({ x: 1, y: 2, next: null, label: 3 }, "abc", (n) => n + 1);
console.log(area({ kind: "circle", r: 2 }), total);
`

// Each access carries the tag of its kind of place; two fields of one layout get two tags, a
// reference field's is under the collector's, and a Tagged slot gets none, since the collector
// reads its tag word. The call of an Allocates export carries the collector's tag; that of an Any
// export carries none.
@(test)
each_kind_of_place_has_its_alias_tag :: proc(t: ^testing.T) {
	output := compile_text(t, ALIAS_PROGRAM)
	text := llvm_text(t, &output, "alias-places")
	if text == "" {
		return
	}
	accesses, parents := tagged_accesses(text)
	wants := [?]Access {
		{"load double", "number element"},
		{"store double", "number element"},
		{"load i8", "boolean element"},
		{"store i8", "boolean element"},
		{"store ptr", "reference element"},
		{"load i64", "array length"},
		{"store i64", "array length"},
		{"load i64", "array capacity"},
		{"load ptr", "array elements"},
		{"load i16", "string"},
		{"load i64", "string"},
		{"load i32", "header"},
		{"load double, ptr @", "global"},
		{"store double", "global"},
		{"load ptr", "closure"},
		{"call ptr @tsnc_string_at", "collector"},
	}
	for want in wants {
		testing.expectf(
			t,
			has_access(accesses, want),
			"no %q tagged %q:\n%s",
			want.line,
			want.place,
			text,
		)
	}

	fields := make(map[string]bool, context.temp_allocator)
	references := 0
	for access in accesses {
		if !strings.has_prefix(access.place, "field ") {
			continue
		}
		if strings.contains(access.line, "double") {
			fields[access.place] = true
		}
		reference :=
			strings.contains(access.line, "load ptr") || strings.contains(access.line, "store ptr")
		references += int(reference)
		parent := "collector" if reference else "tsnc"
		testing.expectf(
			t,
			parents[access.place] == parent,
			"%q is under %q: %s",
			access.place,
			parents[access.place],
			access.line,
		)
	}
	testing.expectf(t, len(fields) >= 2, "x and y of Point share a tag: %v\n%s", fields, text)
	testing.expectf(t, references > 0, "no reference field is read or written:\n%s", text)

	collected := [?]string {
		"header",
		"array length",
		"array capacity",
		"array elements",
		"reference element",
	}
	for place in collected {
		testing.expectf(t, parents[place] == "collector", "%q is under %q", place, parents[place])
	}
	free := [?]string {
		"collector",
		"string",
		"number element",
		"boolean element",
		"global",
		"closure",
	}
	for place in free {
		testing.expectf(t, parents[place] == "tsnc", "%q is under %q", place, parents[place])
	}

	lines, _ := strings.split_lines(text, context.temp_allocator)
	for line in lines {
		untagged :=
			strings.contains(line, "store %tsnc.tagged") ||
			strings.contains(line, "@tsnc_array_join(") ||
			strings.contains(line, "@llvm.memset") ||
			strings.contains(line, "ptr @heap")
		if untagged && strings.contains(line, "!tbaa") {
			testing.expectf(t, false, "an access that may touch anything has a tag: %s", line)
		}
	}
}

// One export per abi.Effect, and a diverging one.
@(test)
each_effect_gives_its_attributes :: proc(t: ^testing.T) {
	output := hello_program(HELLO)
	text := llvm_text(t, &output, "alias-effects")
	if text == "" {
		return
	}
	wants := [?][2]string {
		{"tsnc_string_equal", "nocallback nounwind memory(read, inaccessiblemem: readwrite)"},
		{"tsnc_string_at", "nocallback nounwind"},
		{"tsnc_array_join", "nocallback nounwind"},
		{"tsnc_array_sort", "nounwind"},
		{"tsnc_fail", "nocallback noreturn nounwind"},
	}
	for want in wants {
		got := attributes_of(text, want[0])
		testing.expectf(t, got == want[1], "%s has { %s }, not { %s }", want[0], got, want[1])
	}
}

Access :: struct {
	line:  string,
	place: string, // the name of the tag's type node
}

has_access :: proc(accesses: []Access, want: Access) -> bool {
	for access in accesses {
		if access.place == want.place && strings.contains(access.line, want.line) {
			return true
		}
	}
	return false
}

// tagged_accesses pairs each instruction that carries an alias tag with the name of the tag's type
// node, and the name of each type node with that of its parent, from the metadata lines
// `!N = !{!"name", !parent, i64 0}` and `!T = !{!N, !N, i64 0}`.
tagged_accesses :: proc(text: string) -> (accesses: []Access, parents: map[string]string) {
	lines, _ := strings.split_lines(text, context.temp_allocator)
	names := make(map[string]string, context.temp_allocator) // type node -> name
	above := make(map[string]string, context.temp_allocator) // type node -> parent node
	nodes := make(map[string]string, context.temp_allocator) // access tag -> type node
	for raw in lines {
		line := strings.trim_right(raw, "\r")
		id, _, body := strings.partition(line, " = !{")
		if !strings.has_prefix(id, "!") || body == "" {
			continue
		}
		if strings.has_prefix(body, "!\"") {
			name, _, rest := strings.partition(body[2:], "\"")
			names[id] = name
			above[id], _, _ = strings.partition(strings.trim_prefix(rest, ", "), ",")
		} else {
			nodes[id], _, _ = strings.partition(body, ",")
		}
	}
	parents = make(map[string]string, context.temp_allocator)
	for id, name in names {
		parents[name] = names[above[id]]
	}
	found := make([dynamic]Access, context.temp_allocator)
	for raw in lines {
		line := strings.trim_right(raw, "\r")
		_, tagged, rest := strings.partition(line, "!tbaa ")
		if tagged == "" {
			continue
		}
		tag, _, _ := strings.partition(rest, ",")
		append(&found, Access{line, names[nodes[tag]]})
	}
	return found[:], parents
}

// attributes_of answers what the braces of the attribute group a declaration names hold.
attributes_of :: proc(text, symbol: string) -> string {
	lines, _ := strings.split_lines(text, context.temp_allocator)
	group := ""
	for raw in lines {
		line := strings.trim_right(raw, "\r")
		if strings.has_prefix(line, "declare ") &&
		   strings.contains(
			   line,
			   strings.concatenate({"@", symbol, "("}, context.temp_allocator),
		   ) {
			_, _, group = strings.partition(line, ") #")
		}
	}
	if group == "" {
		return ""
	}
	prefix := strings.concatenate({"attributes #", group, " = { "}, context.temp_allocator)
	for raw in lines {
		line := strings.trim_right(raw, "\r")
		if strings.has_prefix(line, prefix) {
			return strings.trim_suffix(line[len(prefix):], " }")
		}
	}
	return ""
}
