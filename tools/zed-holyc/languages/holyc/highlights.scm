; HolyC syntax highlighting for Zed.

; Comments
(comment) @comment

; Types
(primitive_type) @type.builtin
(type_identifier) @type

; Functions
(function_declarator
  declarator: (identifier) @function.definition)
(function_declarator
  declarator: (pointer_declarator
    declarator: (identifier) @function.definition))

(call_expression
  function: (identifier) @function)
(call_expression
  function: (field_expression
    field: (field_identifier) @function))

; Parameters, properties, members
(parameter_declaration
  declarator: (identifier) @variable.parameter)
(parameter_declaration
  declarator: (pointer_declarator
    declarator: (identifier) @variable.parameter))
(parameter_declaration
  declarator: (array_declarator
    declarator: (identifier) @variable.parameter))

(field_identifier) @property
(property_identifier) @property
(designated_initializer
  designator: (field_identifier) @property)

; Labels
(labeled_statement
  label: (statement_identifier) @label)
(goto_statement
  label: (statement_identifier) @label)

; Literals
(string_literal) @string
(string_content) @string
(system_lib_string) @string
(escape_sequence) @string.escape
(char_literal) @string
(number_literal) @number
(lastclass) @constant.builtin

; Preprocessor
(preproc_include "#" @keyword "include" @keyword)
(preproc_define "#" @keyword "define" @keyword)
(preproc_function_def "#" @keyword "define" @keyword)
(preproc_undef "#" @keyword "undef" @keyword)
(preproc_directive "#" @keyword directive: _ @keyword)
(preproc_define name: (identifier) @constant)
(preproc_function_def name: (identifier) @function)
(preproc_params (identifier) @variable.parameter)
(preproc_undef name: (identifier) @constant)
(preproc_arg) @string.special
(preproc_include path: (string_literal) @string)
(preproc_include path: (system_lib_string) @string)

; Keywords
[
  "if" "else"
  "switch" "sub_switch" "case" "default" "start" "end"
  "for" "while" "do"
  "break" "goto" "return"
  "try" "catch" "throw"
  "lock" "no_warn"
] @keyword

[
  "class" "union"
] @keyword

[
  "public" "extern" "_extern"
] @keyword

[
  "sizeof" "offset"
] @keyword

; Operators
[
  "+" "-" "*" "/" "%"
  "=" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>="
  "++" "--"
  "==" "!=" "<" ">" "<=" ">="
  "&&" "||" "^^" "!"
  "&" "|" "^" "~" "<<" ">>"
  "`"
  "."
  "->"
] @operator

; Punctuation
[
  "(" ")" "[" "]" "{" "}"
] @punctuation.bracket

[
  "," ";" ":" "..."
] @punctuation.delimiter

; Storage classes (reg / noreg)
[
  "reg" "noreg"
] @keyword

; The physical register a `reg <REG> x` variable is pinned to.
(register_name (identifier) @variable.special)

; Inline assembly
"asm" @keyword

; The architecture qualifier on a non-default block: `asm arm64 { … }`,
; `asm riscv64`, `asm ppc64le`, `asm s390x`, … (any qualifier the compiler
; supports — this capture is not tied to a fixed set).
(asm_arch) @label

; Instruction mnemonics (mov, add, imul, …).
(asm_instruction
  mnemonic: (asm_mnemonic) @function)

; Register-name operands (rax, x0, sp, …), distinguished from variables by name.
(asm_instruction
  operand: (identifier) @variable.special
  (#match? @variable.special "^(r[a-z]x|r[a-z]i|r[a-z]p|r[0-9]+|[xw][0-9]+|sp|xzr)$"))

; Variables (fallback — keep last so specific captures win)
(identifier) @variable
