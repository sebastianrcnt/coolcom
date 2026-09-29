open OUnit2
open Austral_core
open CRepr

let rejects expression =
  let unit = CUnit ("Test", [CFunctionDefinition
    (Desc "unsupported embed", "test", [], CNamedType "au_unit_t",
     CReturn expression)]) in
  try
    let _ = HCRenderer.render [unit] None in
    assert_failure "an unsupported C embed was accepted"
  with Error.Austral_error _ -> ()

let suite = "HolyC embed boundary" >::: [
  "reject mixed operators in printf" >:: (fun _ ->
    rejects (CEmbed (CNamedType "au_unit_t", "au_printf(\"%i\", $1 + $2)",
                    [CInt "1"; CInt "2"])));
  "reject arbitrary runtime arguments" >:: (fun _ ->
    rejects (CEmbed (CNamedType "au_unit_t", "au_free($1 + 1)", [CInt "0"])));
  "reject casts with different intermediate semantics" >:: (fun _ ->
    rejects (CEmbed (CNamedType "au_nat8_t", "((double)($1))", [CInt "1"])));
]

let () = run_test_tt_main suite
