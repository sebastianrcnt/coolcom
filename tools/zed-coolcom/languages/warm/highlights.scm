; Warm syntax highlighting for Zed.

; Comments and docstrings
(comment) @comment
(docstring) @comment.doc

; Literals
(string) @string
(string_content) @string
(character) @string
(character_content) @string
(escape_sequence) @string.escape
(integer) @number
(float) @number
(boolean) @boolean
(nil) @constant.builtin

; Types
(type_identifier) @type
((type_identifier) @type.builtin
  (#match? @type.builtin "^(Unit|Bool|Nat8|Nat16|Nat32|Nat64|Int8|Int16|Int32|Int64|Index|ByteSize|Float32|Float64|Address|Pointer|Option|Either|ExitCode|RootCapability|Static)$"))
(universe) @type.builtin

; Functions and methods
(function_declaration name: (identifier) @function.definition)
(method_declaration name: (identifier) @function.definition)
(call_expression function: (identifier) @function)
(pragma name: (identifier) @attribute)

; Modules
(module_name (identifier) @namespace)
(import_declaration module: (module_name (identifier) @namespace))

; Parameters, bindings, fields, constructors
(parameter name: (identifier) @variable.parameter)
(binding name: (identifier) @variable.parameter)
(binding rename: (identifier) @variable)
(slot name: (identifier) @property)
(path_expression field: (identifier) @property)
(reference_path field: (identifier) @property)
(constructor name: (identifier) @constructor)
(when_clause name: (identifier) @constructor)
(argument name: (identifier) @variable.parameter)
(import_symbol name: (identifier) @function)
(import_symbol alias: (identifier) @function)
(constant_declaration name: (identifier) @constant)

; Keywords
[
  "module" "body" "is" "end" "import" "as" "pragma"
  "constant" "type" "function" "generic" "record" "union"
  "typeclass" "instance" "method" "case" "of" "when"
  "let" "var" "borrow" "return" "skip" "sizeof" "@embed"
  "Span" "Span!"
] @keyword

[
  "if" "then" "else" "else if"
  "while" "for" "do" "from" "to"
] @keyword.control

[
  "and" "or" "not"
] @keyword.operator

; Operators
[
  "+" "-" "*" "/" "=" "/=" "<" "<=" ">" ">="
  ":=" "=>" "->" "." "&" "&!" "&~" "&(" "!"
] @operator

; Punctuation
[
  "(" ")" "[" "]" "{" "}"
] @punctuation.bracket

[
  "," ";" ":"
] @punctuation.delimiter

; Variables (fallback; keep last so specific captures win)
(identifier) @variable
