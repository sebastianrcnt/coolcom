; Warm blocks are keyword-delimited: `is ... end;`, `then ... end if;`, `do ... end while;`.
; The whole declaration/statement is an indent range, closed by its `end`.

(module_definition "end" @end) @indent
(function_declaration "end" @end) @indent
(method_declaration "end" @end) @indent
(instance_declaration "end" @end) @indent
(typeclass_declaration "end" @end) @indent
(record_declaration "end" @end) @indent
(union_declaration "end" @end) @indent
(if_statement "end" @end) @indent
(case_statement "end" @end) @indent
(while_statement "end" @end) @indent
(for_statement "end" @end) @indent
(borrow_statement "end" @end) @indent

; A case arm and a union constructor indent their own bodies.
(when_clause) @indent
(constructor "is") @indent

; else / else if start a new branch at the level of the `if`.
(else_clause "else" @outdent)
(else_if_clause "else if" @outdent)

[
  (parameters)
  (arguments)
  (type_parameters)
] @indent
