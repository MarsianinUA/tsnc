# Test corpus map

A working file for T5.11 to T5.16 of `tasks-tsnc.md`. It was made on September 27, 2026, by reading every `@(test)` procedure under `tests/` and every program of the three corpora. Each task strikes its own section when it is done, and T5.16 deletes the file.

T5.11 is done: its two sections are gone, and the tests it kept went into the sections of the tasks that can pin what they assert. T5.12 is done too: its section went with the tests it replaced, and `tests/expect` holds the programs. So is T5.13: its section went the same way, and `tests/negative` holds a program for every code of the `diag` registry. So is T5.14: the check and lower tests of its section are programs of `tests/diff/src` now, nine new ones and lines in ten others. So is T5.15: the runtime, codegen, parse, program and check tests of its section are programs too, seven new ones, `array-join.ts` grown out of `join-separator.ts`, and lines in eleven others. What no program can see stayed as five short tests: a result that allocates nothing, a refusal passed on, and the line ends inside literals that a checkout rewrites.

The map is a reading, not a proof. Before a test goes, open the program named next to it and confirm that it reaches the same construct: the same built-in and corner, or the same diagnostic code on the same kind of construct. When it does not, the test moves instead of going.

Short names: `neg/` is `tests/negative`, `diff/` is `tests/diff/src`, `drv/` is `tests/driver/projects`. A line number after a program points at the statement that covers the test.

Classes:

- DUP: the behavior is already pinned by the named corpus program; the test goes.
- DROP: a lower test that asserts an exact instruction count or order and guards no decision; the test goes.
- MOVE-DIFF, MOVE-NEG: the behavior is visible in a program's output or diagnostics but no program pins it yet; it becomes a program or a line of one, then the test goes.
- NODE-DIFFERS: visible in the output, but Node is not the reference (a runtime failure); it moves to `tests/expect`.
- KEEP-STRATEGY: a lower test that guards a decision no program shows; it stays and gets rewritten in T5.16.
- KEEP: needs internal state or more inputs than a program can hold; it stays.

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
- tests/runtime/arr, 11: `new_zeroed`, the three GC-stress tests of collect_test, the three refusals where Node would run a user function (join, ToPrimitive, default sort of a function), comparator call counts, an inconsistent comparator, `fewer_than_two_elements_call_nothing` (`heap.used`), and `an_empty_result_takes_no_buffer`.
- tests/runtime/console, 4: `color_depth` (50 environments on two platforms), the two width tests (every code point; Hangul differs from Node on purpose), `a_specifier_refuses_what_node_would_run`.
- tests/runtime/str, 8: invalid UTF-8, the maximum length, the static empty cell, a result that is an argument coming back as that cell, the `toFixed` refusal passed on, case mapping of every code point, two GC-stress tests.
- tests/runtime/num, 6: 300,000 random doubles, the two buffer size promises, the `toFixed` range refusal, long literals (bignum inputs), exit codes.
- tests/runtime/value, 3: the refusal test, `load`, and the static words of typeof and String.
- tests/runtime/gc, fail, tests/llvm, abi, target, source, diag, ast: all.
- tests/bind, 49: symbol tables, capture lists and flags, declaration positions, import and export tables, flow-graph dumps.
- tests/parse, about 40: AST dumps, token streams and spans, tree invariants over broken input, the T1012 nesting sweep, and the line ends inside literals that a checkout with autocrlf rewrites.
- tests/program, 2: init order under permutation, determinism.
- tests/link, 6: the four link errors, arguments with spaces and quotes, the Windows check that no `.lib` file is written.
- tests/driver: file order, cycles, CLI and output paths, the in-process build with a non-ASCII path.
