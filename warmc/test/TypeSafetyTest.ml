(*
   Warm fork of the Austral project, under the Apache License v2.0 with LLVM Exceptions.
   See LICENSE for details.

   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
*)
open OUnit2
open Austral_core.Type
open Austral_core.Identifier
open Austral_core.TypeMatch

let test_type_arity _ =
  let name = make_ident "Box" in
  let source = make_mod_name "Test" in
  let qname = make_qident (source, name, name) in
  let one = NamedType (qname, [Boolean], FreeUniverse) in
  let two = NamedType (qname, [Boolean; Boolean], FreeUniverse) in
  assert_bool "named types with different arity are unequal" (not (equal_ty one two));
  let one_fn = FnPtr ([Boolean], Unit) in
  let two_fn = FnPtr ([Boolean; Boolean], Unit) in
  assert_bool "function pointers with different arity are unequal" (not (equal_ty one_fn two_fn))

let test_size_t_bounds _ =
  let max = Z.pred (Z.shift_left Z.one Sys.word_size) in
  let over = Z.succ max in
  List.iter (fun width ->
    assert_bool "size_t maximum fits" (fits Unsigned width max);
    assert_bool "size_t maximum plus one does not fit" (not (fits Unsigned width over));
    assert_bool "values above 255 fit on supported hosts"
      (fits Unsigned width (Z.of_int 256))) [WidthIndex; WidthByteSize]

let suite = "Type safety" >::: [
  "type arity" >:: test_type_arity;
  "size_t bounds" >:: test_size_t_bounds
]

let _ = run_test_tt_main suite
