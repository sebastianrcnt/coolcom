; Outline / symbol panel entries for Zed.

(module_definition
  "module" @context
  name: (module_name) @name) @item

(constant_declaration
  "constant" @context
  name: (identifier) @name) @item

(type_declaration
  "type" @context
  name: (type_identifier) @name) @item

(record_declaration
  "record" @context
  name: (type_identifier) @name) @item

(union_declaration
  "union" @context
  name: (type_identifier) @name) @item

(function_declaration
  "function" @context
  name: (identifier) @name) @item

(typeclass_declaration
  "typeclass" @context
  name: (type_identifier) @name) @item

(instance_declaration
  "instance" @context
  name: (type_identifier) @name
  argument: (_) @context.extra) @item

(method_declaration
  "method" @context
  name: (identifier) @name) @item

(slot
  name: (identifier) @name) @item

(constructor
  "case" @context
  name: (identifier) @name) @item
