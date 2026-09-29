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

let contains text fragment =
  try ignore (Str.search_forward (Str.regexp_string fragment) text 0); true
  with Not_found -> false

let foreign_test _ =
  let i = CNamedType "au_int64_t" in
  let p = CPointer (CNamedType "au_nat8_t") in
  let unit = CUnit ("Test", [CFunctionDefinition
    (Desc "foreign", "test", [], i, CBlock [
      CLocalFunctionDeclaration ("KernelProbe", [CValueParam ("p", p)], i, LinkageExternal);
      CReturn (CFuncall ("KernelProbe", [CCast (CInt "0", p)]))])]) in
  let source = HCRenderer.render [unit] None in
  assert_bool "foreign symbol kept verbatim" (contains source " = KernelProbe(");
  assert_bool "foreign symbol must not be mangled" (not (contains source "wh_KernelProbe"))

let rejects_foreign_span_result _ =
  let span = CNamedType "au_span_t" in
  let pointer = CPointer (CNamedType "au_nat8_t") in
  let unit = CUnit ("Test", [CFunctionDefinition
    (Desc "span return", "test", [], span, CBlock [
      CLocalFunctionDeclaration ("GetBytes", [], pointer, LinkageExternal);
      CReturn (CFuncall ("GetBytes", []))])]) in
  try
    ignore (HCRenderer.render [unit] None);
    assert_failure "pointer return cannot manufacture a span length"
  with Error.Austral_error _ -> ()

let suite = "HolyC embed boundary" >::: [
  "general foreign call" >:: foreign_test;
  "reject foreign span result" >:: rejects_foreign_span_result;
  "reject mixed operators in printf" >:: (fun _ ->
    rejects (CEmbed (CNamedType "au_unit_t", "au_printf(\"%i\", $1 + $2)",
                    [CInt "1"; CInt "2"])));
  "reject arbitrary runtime arguments" >:: (fun _ ->
    rejects (CEmbed (CNamedType "au_unit_t", "au_free($1 + 1)", [CInt "0"])));
  "reject casts with different intermediate semantics" >:: (fun _ ->
    rejects (CEmbed (CNamedType "au_nat8_t", "((double)($1))", [CInt "1"])));
]

let () = run_test_tt_main suite
