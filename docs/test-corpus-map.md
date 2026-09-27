# Test corpus map

A working file for T5.11 to T5.16 of `tasks-tsnc.md`. It was made on September 27, 2026, by reading every `@(test)` procedure under `tests/` and every program of the three corpora. Each task strikes its own section when it is done, and T5.16 deletes the file.

T5.11 is done: its two sections are gone, and the tests it kept went into the sections of the tasks that can pin what they assert.

The map is a reading, not a proof. Before a test goes, open the program named next to it and confirm that it reaches the same construct: the same built-in and corner, or the same diagnostic code on the same kind of construct. When it does not, the test moves instead of going.

Short names: `neg/` is `tests/negative`, `diff/` is `tests/diff/src`, `drv/` is `tests/driver/projects`. A line number after a program points at the statement that covers the test.

Classes:

- DUP: the behavior is already pinned by the named corpus program; the test goes.
- DROP: a lower test that asserts an exact instruction count or order and guards no decision; the test goes.
- MOVE-DIFF, MOVE-NEG: the behavior is visible in a program's output or diagnostics but no program pins it yet; it becomes a program or a line of one, then the test goes.
- NODE-DIFFERS: visible in the output, but Node is not the reference (a runtime failure); it moves to `tests/expect`.
- KEEP-STRATEGY: a lower test that guards a decision no program shows; it stays and gets rewritten in T5.16.
- KEEP: needs internal state or more inputs than a program can hold; it stays.

## Expected-output corpus

T5.12. A failed check writes `error: <name> at <path>:L:C` to stderr and exits with 1 (`src/runtime/fail/fail.odin`, `write_message`). The path is the display path `tsnc build` was given, cleaned, with forward slashes; a relative build prints the same text on every OS.

### From tests/driver/build_test.odin

`expect_failure` builds at `-o:none` in process and runs the result. Its eight runs become programs, and the fixtures go if no other driver test reads them:

| Fixture | stdout | Message | Position |
|---|---|---|---|
| non-null/main.ts | `4` | non-null assertion failed | 5:41 |
| non-null/as.ts | `1` | type assertion failed | 5:9 |
| any-union/main.ts | (none) | a value holds a kind its type does not allow | 6:7 |
| early-read/object.ts | `before` | cannot access a variable before its initialization | 5:9 |
| early-read/number.ts | (none) | the same | 4:9 |
| early-read/function.ts | (none) | the same | 4:9 |
| early-read/captured.ts | (none) | the same | 5:29 |
| early-read/switch.ts | `2` | the same | 9:4 |

Tests replaced: a_failed_non_null_assertion_ends_the_program, a_failed_type_assertion_ends_the_program, an_any_given_to_a_union_it_fits_no_member_of_ends_the_program, a_read_before_initialization_ends_the_program. Positions shift by the header lines a program gains. non-null/as.ts is the only `as` in any corpus that narrows a union, so its program must keep the narrowing that passes (`1`) as well as the one that fails.

### Failure paths no test runs yet

- An early read through an inlined callback: `[1].map(x => x + later)` and the `forEach` form. Replaces lower/bindings a_local_read_early_through_a_closure_is_checked_in_its_box and the run-time half of check/reachability a_name_used_in_a_function_before_its_declaration_is_left_to_the_run.
- `reduce` of an empty array with no initial value ("Reduce of empty array with no initial value"). Replaces lower/arrays reduce_without_an_initial_value_fails_on_an_empty_array.
- A string index past the end ("index out of range"; Node answers `undefined`). Replaces lower/strings an_index_into_a_string_is_checked_and_read_by_the_runtime.
- `x!` on an object that is null. Replaces lower/unions a_non_null_assertion_fails_on_null_and_undefined.
- `v as number | Circle` on a value that is neither. Replaces lower/unions as_to_a_narrower_union_tests_membership.
- A read through the narrow type after a write through the wide one (Field_Holds_Other_Kind), and a widened parameter given a value of another kind through `any` (Value_Of_Other_Kind). Their tests went in T5.11 as DUP; only the failure is new.
- A `let` read in a later case of its `switch`, jumped to directly: `case 1: return y + 1;` above the `let y` of `case 2`. The early-read/switch.ts fixture fails on a write, which lower checks at another place. Replaces lower/bindings a_let_read_in_a_later_case_of_its_switch_is_checked_in_its_box.

## Negative moves

T5.13.

### From tests/check

Each test becomes `// expect:` lines in the program named, one per site; `x2` and so on count the sites. Tests marked [msg] also need the quoted text of the new syntax. The six tests whose diagnostic comes from lower are under "Build mode" below.

- arrays: an_element_that_does_not_fit_the_context_is_reported -> type-mismatch.ts, T3001
- arrays: indexing_with_something_other_than_a_number_is_reported -> type-mismatch.ts, T3001
- arrays: arrays_of_different_elements_do_not_fit_each_other -> type-mismatch.ts, T3001
- arrays: two_array_members_leave_an_empty_literal_without_a_context -> empty-array-literal.ts, T3017
- assertions: as_unknown_as_a_type_is_rejected_at_its_first_half -> unsafe-assertion.ts, T3019 x2
- assertions: non_null_after_a_narrowing_has_nothing_left_to_check -> needless-non-null.ts, T3021
- expressions: comparisons_order_two_numbers_or_two_strings -> comparison-operands.ts, T3005
- expressions: double_equals_on_a_type_of_several_kinds_asks_for_triple_equals -> loose-equality.ts, T3002 x4
- expressions: update_operators_need_a_number -> operand-not-number.ts, T3003
- expressions: assignment_checks_the_declared_type -> type-mismatch.ts, T3001
- expressions: compound_assignment_follows_its_operator -> operand-not-number.ts, T3003
- expressions: an_assertion_between_two_unions_that_merely_overlap_is_reported -> unrelated-assertion.ts, T3020
- functions: a_call_checks_the_type_of_each_argument -> type-mismatch.ts, T3001
- functions: a_call_checks_how_many_arguments_it_passes -> argument-count.ts, T3007 (the too-few case)
- functions: a_function_that_asks_for_more_does_not_fit -> type-mismatch.ts, T3001
- functions: a_function_result_that_does_not_fit_is_reported -> type-mismatch.ts, T3001
- functions: a_positional_array_does_not_fit_a_rest_parameter -> type-mismatch.ts, T3001
- functions: a_required_parameter_does_not_fit_an_optional_one -> type-mismatch.ts, T3001
- functions: an_arrow_parameter_from_an_optional_one_may_be_undefined -> addition-operands.ts, T3004
- generics: an_arrow_parameter_that_does_not_fit_is_reported -> type-mismatch.ts, T3001
- generics: an_arrow_outside_a_call_still_needs_its_annotations -> missing-annotation.ts, T3008
- generics: a_body_that_does_not_fit_the_signature_is_reported -> type-mismatch.ts, T3001
- generics: the_wrong_number_of_arguments_is_reported -> argument-count.ts, T3007
- inference: a_return_is_checked_against_the_declared_result -> type-mismatch.ts, T3001
- inference: mutually_recursive_functions_need_an_annotation -> recursive-return-type.ts, T3010
- inference: a_recursive_arrow_without_a_return_type_needs_an_annotation -> recursive-return-type.ts, T3010
- inference: a_variable_read_from_a_function_that_types_it_is_reported -> circular-initializer.ts, T3027
- members: a_misspelled_member_is_reported -> field-not-found.ts, T3011
- members: a_member_of_the_wrong_type_is_reported -> type-mismatch.ts, T3001
- modules: a_name_the_other_module_does_not_export_is_reported -> unknown-export.ts, T4009 (needs a declared, unexported const in modules/values.ts)
- modules: a_module_namespace_is_not_a_value_of_its_own -> namespace-as-value.ts, T2026 (the type position)
- modules: a_name_a_module_namespace_does_not_have_is_reported -> unknown-export.ts, T4009
- modules: an_imported_type_is_not_a_value -> type-used-as-value.ts, T4010 x3 and T4008 (needs a module that re-exports a type only)
- modules: an_imported_binding_cannot_be_assigned_to -> assign-to-const.ts, T3009
- modules: a_binding_reached_through_a_namespace_cannot_be_assigned_to -> assign-to-const.ts, T3009 (the `++` case)
- names: a_parameter_with_no_type_is_reported -> missing-annotation.ts, T3008
- names: a_name_used_above_its_declaration_is_typed_once -> operand-not-number.ts, T3003 (one line proves "once")
- names: a_mistake_inside_a_rejected_construct_is_still_found -> prototype.ts, T2024 and T3003
- names: a_mistake_inside_a_nested_function_is_reported_once -> operand-not-number.ts, T3003
- narrowing: a_union_has_no_members_of_its_own_outside_a_narrowing -> field-not-found.ts, T3011
- narrowing: a_member_of_a_discriminated_union_is_not_readable_before_the_test -> field-not-found.ts, T3011
- narrowing: a_case_the_value_can_never_equal_is_reported -> no-overlap.ts, T3022
- narrowing: an_optional_field_read_without_a_test_does_not_fit_the_type -> type-mismatch.ts, T3001
- narrowing: a_write_of_the_wrong_type_is_still_reported_inside_a_narrowing -> type-mismatch.ts, T3001
- narrowing: a_write_to_the_object_drops_what_was_known_about_its_field -> type-mismatch.ts, T3001
- narrowing: a_write_at_the_end_of_a_loop_reaches_the_top_of_the_next_turn -> field-not-found.ts, T3011
- narrowing: a_narrowing_does_not_carry_into_an_arrow_when_the_name_is_written_to -> field-not-found.ts, T3011
- narrowing: a_break_out_of_a_loop_carries_what_the_body_left -> type-mismatch.ts, T3001
- narrowing: a_read_after_a_call_that_never_returns_keeps_the_declared_type -> field-not-found.ts, T3011 (the unreachable read is still reported, once)
- narrowing: a_write_to_a_field_of_a_union_fits_every_member -> type-mismatch.ts, T3001 (the accepted half goes to union-fields.ts in T5.14)
- objects: an_unknown_type_name_is_reported -> cannot-find-name.ts, T4008 (the type position)
- objects: a_generic_of_ones_own_is_rejected_at_its_declaration -> generic-declaration.ts, T2023 (reported once)
- objects: a_field_whose_type_does_not_fit_is_reported -> type-mismatch.ts, T3001
- objects: two_object_types_with_different_fields_do_not_fit -> field-not-found.ts, T3011
- objects: a_value_that_is_not_a_literal_needs_the_same_set_of_fields -> missing-field.ts, T3012
- objects: a_literal_whose_tag_fits_no_member_is_reported_once -> type-mismatch.ts, T3001
- objects: a_tag_written_as_a_name_falls_back_to_the_field_names -> type-mismatch.ts, T3001
- reachability: an_arrow_that_can_end_without_a_return_is_reported -> missing-return.ts, T3024
- reachability: a_switch_that_leaves_a_case_out_still_needs_a_return -> missing-return.ts, T3024
- reachability: a_let_read_before_any_write_is_reported -> used-before-assigned.ts, T3025
- reachability: a_compound_assignment_reads_the_target_before_it_writes -> used-before-assigned.ts, T3025 x2
- reachability: a_read_inside_a_function_declaration_is_reported -> used-before-assigned.ts, T3025
- reachability: a_read_inside_an_arrow_made_before_the_write_is_reported -> used-before-assigned.ts, T3025
- reachability: an_exported_let_with_no_initializer_is_reported_at_its_declaration -> used-before-assigned.ts, T3025 (see "Diagnostics in two files")
- reachability: a_name_used_where_it_stands_before_its_declaration_is_reported -> used-before-declaration.ts, T3028 x4
- statements: looping_over_something_that_is_no_sequence_is_reported -> not-iterable.ts, T3023 (the object and union cases)
- statements: a_for_of_variable_cannot_be_written_to -> assign-to-const.ts, T3009
- subset: declare_outside_the_lib_file_is_rejected -> declare.ts, T2022 (function, interface, type)
- subset: type_parameters_of_ones_own_are_rejected -> generic-declaration.ts, T2023 x4
- subset: the_prototype_chain_is_rejected -> prototype.ts, T2024 x3
- subset: the_prototype_chain_is_rejected_on_a_value_the_rules_gave_up_on -> prototype.ts, T2024
- subset: symbol_is_rejected_by_name -> symbol.ts, T2025 x3 and T4008
- subset: changing_the_shape_of_an_object_is_already_closed -> field-not-found.ts, T3011 (a write to a missing field)
- subset: a_function_converted_to_a_string_is_rejected -> function-to-string.ts, T2028 x6 and T3001
- subset: an_operation_on_any_that_converts_it_is_rejected -> any-operation.ts, T2029 x3 [msg]
- subset: every_operation_on_any_that_needs_a_lookup_is_rejected -> any-operation.ts, T2029 x10

type-mismatch.ts takes 21 of these lines; split it into three programs (values and calls, function types, flow) so that each stays short enough to read.

### Build mode: codes lower reports

- not-lowered.ts (T2027): check/functions a_rest_parameter_takes_any_number_of_arguments; lower/closures a_function_with_a_rest_parameter_is_reported; lower/builtins the_four_math_names_the_ir_cannot_say_are_reported (`Math.clz32`, `fround`, `hypot`, `imul`); lower/control_flow poison_nothing_reported_is_named_at_the_expression. Also `x ??= 1`.
- any-to-function.ts (T2029): lower/unions an_any_nested_in_a_flow_never_becomes_a_function, any_never_becomes_a_function.

### Message and hint text

- check/assertions: as_any_is_rejected ("`as any`"), as_between_two_unrelated_types_is_rejected ("cannot be converted"), non_null_on_a_value_that_is_always_there_is_rejected ("nothing to check")
- check/expressions: strict_equality_rejects_two_types_with_no_value_in_common ("no value in common"), comparing_different_types_with_double_equals_asks_for_triple_equals (hint "use `===`")
- check/modules: the_message_about_an_unknown_export_names_the_module (the whole message)
- check/objects: an_extra_field_is_reported_with_a_hint ("`z` is not a field of type `Point`", hint "check the spelling")
- check/subset: the_hint_of_declare_says_what_to_write_instead, an_operation_on_any_that_converts_it_is_rejected ("a value of type `any` cannot be an operand of `*`")
- parse/subset: other_constructs_outside_v1_are_named ("`debugger` statements"). Its sites are already `// expect:` lines of the unsupported-*.ts programs; only the text is left.

### Diagnostics in two files

- check/modules: a_re_export_of_a_name_that_is_nowhere_is_reported, a_ring_of_re_exports_answers_that_the_name_is_nowhere (T4009 at 1:10 in both files), a_result_inferred_through_a_ring_of_imports_is_reported_once
- check/reachability: an_exported_let_with_no_initializer_is_reported_at_its_declaration (the importer stays silent)
- driver/closure_test: a_cycle_of_modules_that_run_code_is_reported (T4007 lands in `a.ts`, not the entry). The two driver check_test cases with errors in several files may follow; they also pin the report's file order.
- program/graph: a_cycle_with_side_effects_is_reported_at_the_import_that_closes_it, one_ring_of_three_modules_is_one_message. Their ring leaves the entry out, so T4007 lands on the import of the ring's first module, and the message lists the ring's modules (a quoted text).
- bind/modules: a_redeclared_export_is_reported_once. Its T4001 sites are in redeclared-name.ts; what is left is the export table, which only an importer sees: the first `export function f` is what `import { f }` gets, and `let f = 1; export function f() {}` exports nothing, so importing `f` is a T4009.

### Lexer and parser codes (from tests/parse)

A parse fragment brings bind and check errors of its own (`f(1, 2` also gives T4008), so each case becomes a whole program with one error per line. `report_syntax` drops a second T1xxx on one line; T1012 skips the rest of the file and needs about 64 nested brackets.

- T1001 unexpected-character.ts: tokenize an_unknown_character_is_reported_and_skipped
- T1002 unterminated-string.ts: a_string_ends_at_the_end_of_its_line; recovery parse_file_reports_the_tokenizer_errors_too
- T1003: an_unterminated_template_runs_to_the_end_of_the_text
- T1004: comments_make_no_tokens
- T1005: a_malformed_number_is_one_token_and_one_diagnostic
- T1006: an_invalid_escape_is_reported_and_the_string_goes_on
- T1007 expected-token.ts: greater_tokens_join_only_when_they_touch, a_missing_part_is_reported_where_it_is_missing, a_member_without_a_type_is_an_error, an_interface_without_a_body_still_has_one, a_skipped_declaration_ends_at_its_body
- T1008: a_body_takes_no_declaration
- T1009, T1010, T1011: operator_rules_are_syntax_errors
- T1012: one program; the nesting sweep over 11 shapes stays a unit test
- recovery, one program each: after_an_error_the_parser_finds_the_next_one, one_syntax_error_per_line_is_reported, a_broken_statement_ends_where_the_next_one_starts, an_error_does_not_hide_the_next_line, an_unclosed_bracket_does_not_swallow_the_file

A parse test goes only when the program pins all it asserts. `parse_checked` runs `check_tree` over every broken input, and `expect_parse` compares the recovered tree: those assertions keep the test.

## Diff moves: check and lower

T5.14. Every program passes the tsc gate: `import type` for a type, a `.ts` specifier, no comparison of two unrelated literal types.

### New programs

1. narrowing-flow.ts: narrowing a_negated_condition_narrows_the_other_way, the_right_side_of_and_knows_what_the_left_one_proved, the_right_side_of_a_coalesce_knows_the_left_one_was_nullish, a_write_inside_a_narrowing_is_measured_against_the_declared_type, a_write_to_another_name_keeps_what_was_known_about_a_field, a_narrowing_carries_into_an_arrow_made_inside_it; statements a_for_of_variable_of_a_union_element_narrows; expressions the_falsy_side_of_or_is_dropped. Check first that tsc narrows the left side of `??` inside its right operand; if not, the coalesce test stays.
2. literal-narrowing.ts: arrays indexing_a_union_of_strings_gives_a_string; expressions not_takes_anything_and_gives_a_boolean; inference a_const_keeps_its_literal_type_and_a_let_widens; narrowing a_switch_groups_the_cases_that_share_one_body, a_default_clause_narrows_to_what_the_cases_left, a_default_clause_of_a_switch_that_leaves_a_member_keeps_it; types a_negative_zero_literal_type_is_the_zero_one (check that tsc takes `const z: 0 = -0`). Pin each narrowed type with an annotated binding, such as `const low: 1 | 2 = die`.
3. returns.ts: inference a_return_type_is_inferred_from_the_body, a_body_that_can_run_off_its_end_also_gives_undefined, a_bare_return_beside_one_with_a_value_gives_undefined; reachability a_result_that_takes_undefined_may_end_without_a_return, a_body_that_ends_in_a_call_that_never_returns_needs_no_return, a_body_that_ends_in_an_endless_loop_needs_no_return; lower/control_flow a_loop_whose_body_always_returns_leaves_nothing_after_it, a_return_inside_a_switch_inside_a_loop, a_void_call_returned_as_a_tagged_value_is_undefined. Call each function only on a path that returns.
4. definite-assignment.ts: reachability a_let_written_on_every_path_is_not_reported, a_let_written_in_every_case_of_an_exhaustive_switch_is_not_reported, a_let_written_before_a_loop_may_be_read_inside_it, a_plain_write_to_a_let_is_no_read, a_read_inside_an_arrow_made_after_the_write_is_not_reported.
5. union-fields.ts: objects a_literal_picks_the_member_of_a_union_its_tag_names; narrowing an_optional_discriminant_survives_a_test_against_undefined; reachability a_body_that_is_an_exhaustive_switch_of_returns_needs_no_return, an_inferred_result_of_an_exhaustive_switch_holds_no_undefined; lower/arrays an_arrow_whose_switch_covers_every_case_runs_off_no_end; lower/unions an_optional_field_of_a_union_reads_as_a_tagged_value, the_length_of_a_string_or_an_array_reads_either, a_compound_assignment_reads_the_narrowed_value (the `u.x += 1` half).
6. contextual-types.ts: arrays an_array_literal_reads_a_context_behind_undefined; assertions a_literal_takes_the_type_it_is_asserted_as (plus one T3020 line in neg/unrelated-assertion.ts); functions an_arrow_that_tests_an_optional_parameter_fits, an_arrow_reads_the_signature_of_an_optional_callback, the_expected_result_reaches_the_body_of_an_arrow; inference an_arrow_with_a_return_type_may_call_itself.
7. structural-types.ts: objects two_interfaces_with_the_same_fields_are_compatible, two_interfaces_that_name_each_other_are_compatible_with_their_twins, readonly_does_not_change_what_a_type_fits.
8. re-exports.ts, with a new modules/relay.ts, and an `export let` plus a function that bumps it in modules/counter.ts: modules an_imported_type_is_the_type_of_its_declaration, an_import_may_rename_what_it_takes, a_re_export_carries_a_name_through; lower/modules an_imported_binding_is_the_other_modules_global.
9. compound-operators.ts: lower/control_flow every_arithmetic_and_bitwise_operator_lowers (`-= /= %= **= <<= >>= >>>= &= |= ^=` appear nowhere in the corpus); lower/objects the_place_is_evaluated_before_the_value (`a[i] = (i = 5)`).

### Extensions

- typeof-narrowing.ts: narrowing typeof_tells_a_function_value_from_a_reference; expressions typeof_gives_the_answers_it_can_produce (compare with "object" and "function"); subset a_union_that_may_hold_a_function_is_converted_at_run_time (the string arm).
- any-values.ts: narrowing typeof_narrows_any_and_unknown_to_a_primitive.
- comparisons.ts: expressions double_equals_between_one_type_is_allowed, strict_equality_accepts_two_unions_that_share_a_member.
- logical.ts: expressions and_keeps_the_falsy_side_and_coalesce_keeps_the_rest.
- never.ts: narrowing a_call_that_never_returns_ends_the_path_it_stands_on; lower/control_flow a_ternary_whose_arms_both_never_return_joins_nothing (declared, never called), a_never_right_side_of_a_short_circuit_leaves_the_left_one (`return n > 0 || process.exit(73)` and the `&&` form).
- math.ts: lower/builtins math_pow_is_the_power_operator (`Math.pow(1, NaN)`), math_sign_answers_the_value_itself_at_zero.
- process-argv.ts: lower/builtins process_argv_is_a_global_main_fills_first (`process.argv === process.argv`).
- closure-loops.ts: lower/closures a_boxed_for_of_variable_and_a_boxed_callback_parameter_are_bound_per_pass.
- callback-arguments.ts: lower/closures a_callback_through_a_closure_gets_the_index_only_where_its_class_can_hold_it.
- widening.ts: lower/widening a_read_of_an_object_out_of_a_widened_slot_checks_its_layout, a_write_through_the_narrow_type_boxes_into_the_slot, two_objects_of_one_class_compare_and_assert_as_they_are.

### Helpers left unused after the move

check: `expect_program`, `use_declaration`, `member_text`. lower: `number_at`, `returned` and the `core:slice` import in control_flow; after T5.13, `expect_later`, `Lowered.constructs`, `slice_equal`.

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
17. Module programs (new): module-ring.ts (program and check a_cycle_of_types_and_functions_is_allowed: a function called from a body across the ring, and a type alias read back through it), type-import-ring.ts (a_type_only_import_orders_nothing), self-import.ts (a_module_that_imports_itself_is_not_a_cycle).

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
- tests/check tests that move in T5.13 once the negative runner reads text and files: the eight under "Message and hint text" and the three check tests under "Diagnostics in two files".
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
