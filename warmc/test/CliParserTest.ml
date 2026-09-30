(*
   Part of the Austral project, under the Apache License v2.0 with LLVM Exceptions.
   See LICENSE file for details.

   SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
*)
open OUnit2
open Austral_core.Identifier
open Austral_core.CliUtil
open Austral_core.CliParser

let parse_cmd (args: string list): cmd =
  parse (parse_args args)

let test_help_cmd _ =
  let cmd: cmd = parse_cmd ["austral"; "--help"] in
  assert_equal cmd HelpCommand

let test_version_cmd _ =
  let cmd: cmd = parse_cmd ["austral"; "--version"] in
  assert_equal cmd VersionCommand

let test_compile_help_cmd _ =
  let cmd: cmd = parse_cmd ["austral"; "compile"; "--help"] in
  assert_equal cmd CompileHelp

let test_compile_default _ =
  let cmd: cmd = parse_cmd ["austral"; "compile"; "foo.warm"; "bar.warmh,bar.warm"; "--entrypoint=Foo:main"; "--output=out"]
  and expected: cmd = WholeProgramCompile {
                          modules = [
                            ModuleBodySource { body_path = "foo.warm" };
                            ModuleSource { inter_path = "bar.warmh"; body_path = "bar.warm" };
                          ];
                          target = Executable {
                                       bin_path = "out";
                                       entrypoint = Entrypoint (make_mod_name "Foo", make_ident "main")
                                     };
                          error_reporting_mode = ErrorReportPlain
                        }
  in
  assert_bool "commands are equal" (equal_cmd cmd expected)

let test_compile_hc _ =
  List.iter (fun (flag, expected) ->
    let cmd = parse_cmd ["warmc"; "compile"; "foo.warm"; "--target-type=hc";
                         "--output=out.cool"; flag] in
    match cmd with
    | WholeProgramCompile { target = HCStandalone {output_path; entrypoint}; _ } ->
        assert_equal "out.cool" output_path;
        assert_equal expected entrypoint
    | _ -> assert_failure "expected a HolyC source target")
    ["--no-entrypoint", None;
     "--entrypoint=Foo:main", Some (Entrypoint (make_mod_name "Foo", make_ident "main"))]

let suite =
  "CliParser" >::: [
      "--help" >:: test_help_cmd;
      "--version" >:: test_version_cmd;
      "compile --help" >:: test_compile_help_cmd;
      "compile default" >:: test_compile_default;
      "compile hc" >:: test_compile_hc;
    ]

let _ = run_test_tt_main suite
