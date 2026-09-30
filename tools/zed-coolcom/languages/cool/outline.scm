; Outline / symbol panel entries for Zed.

(class_specifier
  "class" @context
  name: (type_identifier) @name) @item

(union_specifier
  "union" @context
  name: (type_identifier) @name) @item

; Function definitions (plain and pointer-returning).
(function_definition
  type: (_) @context
  declarator: (function_declarator
    declarator: (identifier) @name)) @item

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @item

(function_definition
  declarator: (pointer_declarator
    declarator: (function_declarator
      declarator: (identifier) @name))) @item

; Function prototypes.
(declaration
  (function_declarator
    declarator: (identifier) @name)) @item

(declaration
  (pointer_declarator
    (function_declarator
      declarator: (identifier) @name))) @item
