# Test corpus map

A working file for T5.11 to T5.16 of `tasks-tsnc.md`. It was made on September 27, 2026, by reading every `@(test)` procedure under `tests/` and every program of the three corpora. Each task strikes its own section when it is done, and T5.16 deletes the file.

T5.11 is done: its two sections are gone, and the tests it kept went into the sections of the tasks that can pin what they assert. T5.12 is done too: its section went with the tests it replaced, and `tests/expect` holds the programs. So is T5.13: its section went the same way, and `tests/negative` holds a program for every code of the `diag` registry. So is T5.14: the check and lower tests of its section are programs of `tests/diff/src` now, nine new ones and lines in ten others.

The map is a reading, not a proof. Before a test goes, open the program named next to it and confirm that it reaches the same construct: the same built-in and corner, or the same diagnostic code on the same kind of construct. When it does not, the test moves instead of going.

Short names: `neg/` is `tests/negative`, `diff/` is `tests/diff/src`, `drv/` is `tests/driver/projects`. A line number after a program points at the statement that covers the test.

Classes:

- DUP: the behavior is already pinned by the named corpus program; the test goes.
- DROP: a lower test that asserts an exact instruction count or order and guards no decision; the test goes.
- MOVE-DIFF, MOVE-NEG: the behavior is visible in a program's output or diagnostics but no program pins it yet; it becomes a program or a line of one, then the test goes.
- NODE-DIFFERS: visible in the output, but Node is not the reference (a runtime failure); it moves to `tests/expect`.
- KEEP-STRATEGY: a lower test that guards a decision no program shows; it stays and gets rewritten in T5.16.
- KEEP: needs internal state or more inputs than a program can hold; it stays.

## Diff moves: runtime and the rest

T5.15. What a program can call: `src/lib/lib.d.ts`. It has no `String.fromCharCode`, `Number()`, `parseInt`, `repeat`, `codePointAt` or `toString(radix)`; `%d` reaches `Number()` and `%i` reaches `parseInt`. `Math.clz32`, `fround`, `hypot` and `imul` give T2027. A lone surrogate comes from a `\uD800` escape or from slicing a pair at run time.

1. arrays.ts: arr slice_copies_into_a_new_array (`slice(0, Infinity)`, `(NaN, 2)`, `(3, 1)`, `(-10, -4)`, `(0, -0)`, result `!==` source), the_search_starts_where_node_starts_it (the eight `fromIndex` values), search_compares_as_node_does (NaN, both zeros, strings built at run time, object identity, union arrays, `(undefined | null)[]`).
2. array-join.ts (new): join_writes_every_element_as_node_does (-0, NaN, 1e21, booleans, a `"\u{1F600}"` separator, undefined and null), a_nested_array_joins_in_place, a_cycle_joins_to_nothing_where_it_closes (check that the subset can build both).
3. sort-comparator.ts: equal_elements_keep_their_order, a_comparator_that_changes_the_array_sees_node_semantics, a_comparator_may_sort_the_same_array, the_sign_of_a_comparator_is_what_counts, a_long_sort_keeps_equal_elements_in_order (5,000 generated keys, print a checksum). A comparator that changes the array does so on its first call only.
4. sort-default.ts (new): the_default_order_is_the_order_of_strings, the_default_order_compares_utf16_units (print `charCodeAt(0)`).
5. strings.ts: console unpaired_surrogate_is_replacement_character; str concat_joins_units (`"\ud83d" + "\ude00"` through a parameter).
6. string-units.ts (new, or into string-methods.ts): str equality_and_order_go_by_units, char_code_at_matches_node, slice_matches_node, unit_at_answers_one_unit, code_point_at_answers_what_for_of_yields, search_matches_node, trim_strips_the_whitespace_of_ecmascript, splitter_matches_node; arr split_matches_node; num positions_become_integers_before_they_become_indices.
7. string-case.ts (new): str case_corners_match_node, final_sigma_matches_node, without the checks that the same cell comes back.
8. numbers.ts: num to_string_matches_node, adding 4.35, 9.999999999999999e20, 1.2e-5, 1e-323, 1e300, 2^53+2, 426147580146789570, 28206292283999998000, 1.3649515199999999e21.
9. number-methods.ts: num to_fixed_matches_node (the carry `99.99` to `100.0`, the near ties, `1e15`, 20 digits, NaN, -0.5, 3.9 digit counts), parse_float_matches_node (`5.`, `.`, `In`, `+Infinity`, last-place rounding, denormals, Unicode whitespace, U+0085); str numbers_meet_cells.
10. format.ts: console what_is_no_specifier_stays_as_it_is (`console.log("%% %s")`), percent_s_is_string_but_inspects_an_object_to_depth_zero, the_number_specifiers_convert_as_node_does, percent_j_is_json, percent_o_shows_the_hidden_properties (without the anonymous function with a prototype), percent_o_groups_its_length_as_node_does, percent_j_of_a_deep_list_needs_no_deep_stack; num to_number_matches_node through `%d`, parse_int_matches_node through `%i`.
11. inspect.ts (new): console arrays_of_each_element_kind, past_the_depth_an_array_and_an_object_print_their_kind, a_long_array_of_numbers_groups_into_right_aligned_columns, other_entries_group_into_left_aligned_columns, a_string_takes_the_quote_it_need_not_escape, a_long_string_breaks_after_its_line_ends, long_values_are_cut_where_node_cuts_them, an_object_prints_its_fields_in_table_order (without `['__proto__']`), a_cycle_prints_a_reference, entries_past_the_break_length_take_a_line_each.
12. colors.ts: console colors_reach_only_what_inspect_prints (`%o` of `[4]`), colors_wrap_each_value_in_its_style.
13. math.ts: num round_takes_a_half_toward_positive_infinity, max_and_min_answer_nan_and_order_the_two_zeros (both argument orders, through `id()`).
14. arithmetic.ts: codegen exponentiation_answers_nan_for_a_unit_base (`1 ** Infinity`, `(-1) ** ±Infinity`, `(-1) ** NaN`).
15. any-values.ts: value typeof_answers_a_static_word_for_every_tag, strict_equality_goes_by_tag, truthiness_matches_node, to_string_matches_node.
16. literals.ts (new): parse numbers_have_their_values (hex, octal, binary, `_` separators, `5.`, `1.e2`, `0xFFFFFFFFFFFFFFFF`, `1e400`, last-place rounding), strings_have_their_cooked_values, template_text_is_cooked. Leave out CRLF and U+2028 line continuations: autocrlf rewrites them.
17. Module programs (new): module-ring.ts (program and check a_cycle_of_types_and_functions_is_allowed: a function called from a body across the ring, and a type alias read back through it), type-import-ring.ts (a_type_only_import_orders_nothing), self-import.ts (a_module_that_imports_itself_is_not_a_cycle). The cycle test is the last caller of `expect_program` in `tests/check/check_helpers.odin`, which goes with it.

Also worth a program, though no test moves there: parse precedence and associativity (`2 ** 3 ** 2`, `a - b - c`, `a = b = c`), the compound assignment operators, `a.default.if`, automatic semicolons (`return\n1`, `a\n(b)`), `c?.5:1`; bind shadowing, a loop header scope, no T3024 after `while (true) {}`, renamed imports, a side-effect `import`, `export { x as y }`.

## Lower decisions

T5.16. Each test keeps its decision and loses its exact counts and positions:

- arrays: the_four_callback_methods_are_loops_with_the_callback_inlined: map, filter, forEach and reduce are loops with no call
- arrays: a_callback_may_be_the_name_of_a_function: a named callback is called directly
- bindings: module_bindings_are_globals: module bindings live in globals
- bindings: every_global_is_zeroed_before_the_module_runs: globals are zeroed, strings get the empty cell
- bindings: a_union_of_one_representation_needs_no_tag: such a union has no tag
- bindings: a_read_made_after_the_declaration_needs_no_check: no early-read check after the declaration
- builtins: math_names_with_an_intrinsic_use_it: Math names lower to intrinsics
- builtins: a_program_that_never_reads_process_argv_has_no_global_for_it: the argv global exists only when read
- closures: a_variable_that_never_changes_is_copied_and_one_that_does_is_boxed: constant captures copied, mutated ones boxed
- closures: a_self_recursive_function_that_captures_nothing_is_called_directly: no box or environment
- closures: two_nested_functions_that_only_call_each_other_are_called_directly: mutual recursion without captures stays direct
- closures: a_module_function_as_a_value_is_its_static_closure: a static closure
- closures: a_let_of_a_for_header_gets_a_box_per_pass: a box per pass, joined by a phi
- closures: sorting_with_a_comparator_passes_the_closure_as_it_stands: no adapter when the classes match
- control_flow: a_local_written_in_a_loop_becomes_a_phi: loop locals are phis
- lib: the_math_names_the_ir_has_an_intrinsic_for_use_it: only four Math names are deferred
- modules: an_imported_function_is_called_directly: no closure for an imported function
- objects: two_interfaces_of_one_shape_share_a_layout: one field set, one layout
- unions: a_narrowed_read_tests_the_tag_and_unboxes: a narrowed read checks the tag first
- unions: a_narrowed_object_is_checked_by_its_layout_too: and an object its layout
- unions: typeof_compared_with_a_word_is_a_tag_test: a tag test, not a runtime call
- unions: typeof_of_a_static_value_is_a_constant: folded to a constant
- unions: a_switch_over_typeof_tests_the_tag_of_each_case: tag tests per case
- unions: a_comparison_with_null_or_undefined_is_a_tag_test: a tag test
- unions: a_nullable_reference_is_truthy_by_its_tag_alone: truthiness by the tag alone
- unions: members_of_one_layout_share_one_arm: one dispatch arm per layout
- control_flow: a_void_function_returns_nothing: a void function has no result and every return is bare

## What stays a unit test

- tests/check, 25:
  - generics: a_call_records_the_signature_it_settled_on (the `node_signatures` contract lower reads)
  - lib: the_lib_file_types_without_a_diagnostic (the lib typed as a partition of its own)
  - modules: one_partition_and_any_split_give_the_same_answer
  - names: the_well_known_types_are_where_the_constants_say (the error row, partition internals), a_checker_reports_only_the_files_of_its_partition
  - narrowing: a_loop_body_with_many_branches_is_walked_once (no 2^N walk), a_narrowing_reads_the_same_in_every_partition
  - objects: object_fields_are_in_canonical_order, an_optional_field_prints_with_its_question_mark, and the seven widening-record tests: every_place_a_narrow_object_flows_records_its_widening, a_widening_walks_into_the_fields, a_widening_of_an_interface_that_names_itself_ends, one_type_and_arrays_record_nothing, a_function_flow_lists_its_pair_and_its_parameters_the_other_way, a_lib_callback_lists_no_pair_of_its_own, a_function_pushed_into_an_array_lists_its_pair
  - types: all eight (Type_ID rows, interning, union canonical form and text order across checkers, function type text, the result outliving the check's scratch)
  - corpus: every_program_of_the_diff_corpus_checks_without_a_diagnostic (`check_typed` over every diff program)
- tests/lower, 5 besides KEEP-STRATEGY: the four lib tests of the strategy table (every lib name has a row, every row names a lib member, no name twice, no dotted name), and control_flow the_dump_is_the_same_every_time.
- tests/ir, all 54: the builder, layout and string interning, the printer's format, 27 verifier faults. None of it reaches a program.
- tests/codegen, 16: the `noreturn` attribute, i1 widened to i64 at runtime calls, a zeroed internal global, the rest array of a runtime call, a tagged value split into words, the result slot, the closure convention, fail sites, `init$m` names and linkage, one call per `console.log`, the rows of `tsnc_roots` (a missing row for a tagged global passes the corpus under stress, since the conservative stack scan finds a stale copy; a Ref global's row is pinned by gc-objects.ts), and all of codegen_test (object and IR emission, `-o:aggressive`, object formats per target, the unsupported target, the write error).
- tests/runtime/arr, 10: `new_zeroed`, the three GC-stress tests of collect_test, the three refusals where Node would run a user function (join, ToPrimitive, default sort of a function), comparator call counts, an inconsistent comparator, `fewer_than_two_elements_call_nothing` (`heap.used`).
- tests/runtime/console, 4: `color_depth` (50 environments on two platforms), the two width tests (every code point; Hangul differs from Node on purpose), `a_specifier_refuses_what_node_would_run`.
- tests/runtime/str, 6: invalid UTF-8, the maximum length, the static empty cell, case mapping of every code point, two GC-stress tests.
- tests/runtime/num, 6: 300,000 random doubles, the two buffer size promises, the `toFixed` range refusal, long literals (bignum inputs), exit codes.
- tests/runtime/value, 2: the refusal test, `load`.
- tests/runtime/gc, fail, tests/llvm, abi, target, source, diag, ast: all.
- tests/bind, 49: symbol tables, capture lists and flags, declaration positions, import and export tables, flow-graph dumps.
- tests/parse, about 40: AST dumps, token streams and spans, tree invariants over broken input, the T1012 nesting sweep.
- tests/program, 2: init order under permutation, determinism.
- tests/link, 6: the four link errors, arguments with spaces and quotes, the Windows check that no `.lib` file is written.
- tests/driver: file order, cycles, CLI and output paths, the in-process build with a non-ASCII path.
