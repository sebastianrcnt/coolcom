// Tree-sitter grammar for Warm (coolcom's fork of Austral): .warmh interfaces and
// .warm bodies. Written from warmc/Lexer.cool and warmc/Parser.cool, so it accepts
// what the compiler's parser accepts (and a little more, e.g. it does not enforce
// "interface has no bodies").

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}

// pragmas, then `private` (Warm: not importable from other modules)
function head($) {
  return seq(repeat($.pragma), optional('private'));
}

// ... and for functions/instances, `private` may also follow `generic [...]`
function generic_head($) {
  return seq(head($), optional(seq($.generic_prefix, optional('private'))));
}

// Loosest to tightest, as in warmc/Parser.cool (WOpLevel). and/or share a level (mixing them
// is a compiler error, not a parse difference), comparisons do not chain.
const PREC = {
  cast: 0,
  logical: 1,
  compare: 2,
  bit_or: 3,
  bit_xor: 4,
  bit_and: 5,
  shift: 6,
  add: 7,
  mul: 8,
  unary: 9,
};

module.exports = grammar({
  name: 'warm',

  word: $ => $.identifier,

  extras: $ => [/\s/, $.comment, $.docstring],

  supertypes: $ => [$._declaration, $._statement, $._expression, $._type],

  rules: {
    // [docstring] {pragma} {import} module ...  (docstrings are extras)
    source_file: $ => seq(
      repeat($.pragma),
      repeat($.import_declaration),
      $.module_definition,
    ),

    comment: _ => token(seq('--', /[^\r\n]*/)),

    // """ ... """ ; the lexer allows \" inside.
    docstring: _ => token(seq(
      '"""',
      repeat(choice(/[^"\\]/, /\\(.|\n)/, /"[^"\\]/, /""[^"\\]/)),
      '"""',
    )),

    // ---------------------------------------------------------------- module

    module_name: $ => seq($.identifier, repeat(seq('.', $.identifier))),

    pragma: $ => seq(
      'pragma',
      field('name', $.identifier),
      optional($.arguments),
      ';',
    ),

    import_declaration: $ => seq(
      'import',
      field('module', $.module_name),
      '(',
      commaSep($.import_symbol),
      ')',
      ';',
    ),

    import_symbol: $ => seq(
      field('name', $.identifier),
      optional(seq('as', field('alias', $.identifier))),
    ),

    module_definition: $ => seq(
      'module',
      optional('body'),
      field('name', $.module_name),
      'is',
      repeat($._declaration),
      'end',
      'module',
      optional('body'),
      '.',
    ),

    // --------------------------------------------------------- declarations

    _declaration: $ => choice(
      $.constant_declaration,
      $.type_declaration,
      $.record_declaration,
      $.union_declaration,
      $.function_declaration,
      $.typeclass_declaration,
      $.instance_declaration,
    ),

    constant_declaration: $ => seq(
      head($),
      'constant',
      field('name', $.identifier),
      ':',
      field('type', $._type),
      optional(seq(':=', field('value', $._expression))),
      ';',
    ),

    type_declaration: $ => seq(
      head($),
      'type',
      field('name', alias($.identifier, $.type_identifier)),
      optional($.type_parameters),
      ':',
      field('universe', $.universe),
      ';',
    ),

    record_declaration: $ => seq(
      head($),
      'record',
      field('name', alias($.identifier, $.type_identifier)),
      optional($.type_parameters),
      ':',
      field('universe', $.universe),
      'is',
      repeat($.slot),
      'end',
      ';',
    ),

    union_declaration: $ => seq(
      head($),
      'union',
      field('name', alias($.identifier, $.type_identifier)),
      optional($.type_parameters),
      ':',
      field('universe', $.universe),
      'is',
      repeat($.constructor),
      'end',
      ';',
    ),

    constructor: $ => seq(
      'case',
      field('name', $.identifier),
      choice(';', seq('is', repeat($.slot))),
    ),

    slot: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $._type),
      ';',
    ),

    function_declaration: $ => seq(
      generic_head($),
      'function',
      field('name', $.identifier),
      $.parameters,
      ':',
      field('result', $._type),
      optional(seq('is', optional($.block), 'end')),
      ';',
    ),

    typeclass_declaration: $ => seq(
      head($),
      'typeclass',
      field('name', alias($.identifier, $.type_identifier)),
      '(',
      $.type_parameter,
      ')',
      'is',
      repeat($.method_declaration),
      'end',
      ';',
    ),

    instance_declaration: $ => seq(
      generic_head($),
      'instance',
      field('name', alias($.identifier, $.type_identifier)),
      '(',
      field('argument', $._type),
      ')',
      optional(seq('is', repeat($.method_declaration), 'end')),
      ';',
    ),

    method_declaration: $ => seq(
      optional($.generic_prefix),
      'method',
      field('name', $.identifier),
      $.parameters,
      ':',
      field('result', $._type),
      optional(seq('is', $.block, 'end')),
      ';',
    ),

    generic_prefix: $ => seq('generic', $.type_parameters),

    type_parameters: $ => seq('[', commaSep($.type_parameter), ']'),

    type_parameter: $ => seq(
      field('name', alias($.identifier, $.type_identifier)),
      ':',
      field('universe', $.universe),
      optional(seq(
        '(',
        commaSep(alias($.identifier, $.type_identifier)),
        ')',
      )),
    ),

    universe: _ => choice('Free', 'Linear', 'Type', 'Region'),

    parameters: $ => seq('(', commaSep($.parameter), ')'),

    parameter: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $._type),
    ),

    // ----------------------------------------------------------------- types

    _type: $ => choice($.type_application, $.reference_type),

    type_application: $ => seq(
      field('name', alias($.identifier, $.type_identifier)),
      optional(seq('[', commaSep($._type), ']')),
    ),

    // &[T, R]  &![T, R]  Span[T, R]  Span![T, R]; in function parameters the region may
    // be left out: Span[T]
    reference_type: $ => seq(
      field('kind', choice('&', '&!', 'Span', 'Span!')),
      '[',
      $._type,
      optional(seq(',', $._type)),
      ']',
    ),

    // ------------------------------------------------------------ statements

    block: $ => repeat1($._statement),

    _statement: $ => choice(
      $.if_statement,
      $.let_statement,
      $.destructure_statement,
      $.case_statement,
      $.while_statement,
      $.for_statement,
      $.borrow_statement,
      $.return_statement,
      $.skip_statement,
      $.assignment_statement,
      $.expression_statement,
    ),

    if_statement: $ => seq(
      'if',
      field('condition', $._expression),
      'then',
      field('then', $.block),
      repeat($.else_if_clause),
      optional($.else_clause),
      'end',
      'if',
      ';',
    ),

    else_if_clause: $ => seq(
      alias(token(seq('else', /[ \t]+/, 'if')), 'else if'),
      field('condition', $._expression),
      'then',
      field('then', $.block),
    ),

    else_clause: $ => seq('else', $.block),

    let_statement: $ => seq(
      choice('let', 'var'),
      field('name', $.identifier),
      ':',
      field('type', $._type),
      ':=',
      field('value', $._expression),
      ';',
    ),

    destructure_statement: $ => seq(
      choice('let', 'var'),
      '{',
      commaSep($.binding),
      '}',
      ':=',
      field('value', $._expression),
      ';',
    ),

    binding: $ => seq(
      field('name', $.identifier),
      optional(seq('as', field('rename', $.identifier))),
      ':',
      field('type', $._type),
    ),

    case_statement: $ => seq(
      'case',
      field('value', $._expression),
      'of',
      repeat($.when_clause),
      'end',
      'case',
      ';',
    ),

    when_clause: $ => seq(
      'when',
      field('name', $.identifier),
      optional(seq('(', commaSep($.binding), ')')),
      'do',
      $.block,
    ),

    while_statement: $ => seq(
      'while',
      field('condition', $._expression),
      'do',
      $.block,
      'end',
      'while',
      ';',
    ),

    for_statement: $ => seq(
      'for',
      field('name', $.identifier),
      'from',
      field('from', $._expression),
      'to',
      field('to', $._expression),
      'do',
      $.block,
      'end',
      'for',
      ';',
    ),

    borrow_statement: $ => seq(
      'borrow',
      field('name', $.identifier),
      ':',
      field('type', $._type),
      ':=',
      field('mode', choice('&', '&!', '&~')),
      field('original', $.identifier),
      'do',
      $.block,
      'end',
      'borrow',
      ';',
    ),

    return_statement: $ => seq('return', $._expression, ';'),

    skip_statement: _ => seq('skip', ';'),

    assignment_statement: $ => seq(
      field('target', $._simple_expression),
      ':=',
      field('value', $._expression),
      ';',
    ),

    expression_statement: $ => seq($._simple_expression, ';'),

    // ----------------------------------------------------------- expressions

    _expression: $ => choice($.if_expression, $._simple_expression),

    // Statements starting with "if" are if statements, never if expressions.
    _simple_expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.cast_expression,
      $._atom,
    ),

    if_expression: $ => prec.right(seq(
      'if',
      field('condition', $._expression),
      'then',
      field('then', $._expression),
      'else',
      field('else', $._expression),
    )),

    binary_expression: $ => {
      const table = [
        [PREC.logical, choice('and', 'or')],
        [PREC.compare, choice('=', '/=', '<', '<=', '>', '>=')],
        [PREC.bit_or, '|'],
        [PREC.bit_xor, '^'],
        [PREC.bit_and, '&'],
        [PREC.shift, choice('<<', '>>')],
        [PREC.add, choice('+', '-')],
        [PREC.mul, choice('*', '/')],
      ];
      return choice(...table.map(([p, op]) => prec.left(p, seq(
        field('left', $._simple_expression),
        field('operator', op),
        field('right', $._simple_expression),
      ))));
    },

    unary_expression: $ => prec(PREC.unary, seq(
      field('operator', choice('not', '-', '~')),
      field('operand', choice($.unary_expression, $._atom)),
    )),

    cast_expression: $ => prec.left(PREC.cast, seq(
      field('value', $._simple_expression),
      ':',
      field('type', $._type),
    )),

    _atom: $ => choice(
      $.integer,
      $.float,
      $.character,
      $.string,
      $.boolean,
      $.nil,
      $.identifier,
      $.call_expression,
      $.path_expression,
      $.parenthesized_expression,
      $.sizeof_expression,
      $.embed_expression,
      $.borrow_expression,
      $.reference_path,
      $.dereference_expression,
    ),

    parenthesized_expression: $ => seq('(', $._expression, ')'),

    call_expression: $ => seq(
      field('function', $.identifier),
      $.arguments,
    ),

    arguments: $ => seq('(', commaSep($.argument), ')'),

    argument: $ => choice(
      seq(field('name', $.identifier), '=>', field('value', $._expression)),
      field('value', $._expression),
    ),

    path_expression: $ => seq(
      field('base', $.identifier),
      repeat1($._path_element),
    ),

    _path_element: $ => choice(
      seq('.', field('field', $.identifier)),
      seq('->', field('field', $.identifier)),
      seq('[', field('index', $._expression), ']'),
    ),

    reference_path: $ => seq(
      '&(',
      field('base', $.identifier),
      repeat1($._path_element),
      ')',
    ),

    borrow_expression: $ => seq(
      choice('&', '&!', '&~'),
      $.identifier,
    ),

    dereference_expression: $ => seq('!', $._atom),

    sizeof_expression: $ => seq('sizeof', '(', $._type, ')'),

    embed_expression: $ => seq(
      '@embed',
      '(',
      $._type,
      ',',
      $.string,
      optional(seq(',', commaSep($._expression))),
      ')',
    ),

    // -------------------------------------------------------------- literals

    boolean: _ => choice('true', 'false'),

    nil: _ => 'nil',

    integer: _ => token(choice(
      /[+-]?[0-9][0-9']*/,
      /#[xX][0-9a-fA-F][0-9a-fA-F']*/,
      /#[oO][0-7][0-7']*/,
      /#[bB][01][01']*/,
    )),

    float: _ => token(
      /[+-]?[0-9][0-9']*\.([+-]?[0-9][0-9']*)?([eE][+-]?[0-9][0-9']*)?/,
    ),

    character: $ => seq(
      "'",
      choice(alias(/[^'\\\n]/, $.character_content), $.escape_sequence),
      "'",
    ),

    string: $ => seq(
      '"',
      repeat(choice(
        alias(token.immediate(prec(1, /[^"\\]+/)), $.string_content),
        $.escape_sequence,
      )),
      '"',
    ),

    escape_sequence: _ => token.immediate(/\\(.|\n)/),

    identifier: _ => /[A-Za-z][A-Za-z0-9_]*/,
  },
});
