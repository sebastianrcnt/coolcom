# tree-sitter-warm

Tree-sitter grammar for Warm (`.warm` bodies and `.warmh` interfaces; the older `.aum`/`.aui`
names parse too). It follows `warmc/Lexer.cool` and `warmc/Parser.cool`: `--` comments,
`"""` docstrings (extras), `else if` as one token, `Span!`, `&!`/`&~`/`&(`, `@embed`, numbers
with `'` separators and `#x`/`#o`/`#b` prefixes.

```sh
cd tools/tree-sitter-warm
tree-sitter generate --abi 14     # writes src/ (committed, Zed builds from it)
tree-sitter test                  # test/corpus
tools/tree-sitter-warm/check-repo.sh   # parse every tracked .warm/.warmh, fail on any error
```

The Zed extension that uses it is `tools/zed-coolcom`.
