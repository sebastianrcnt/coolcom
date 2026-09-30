# zed-coolcom

One Zed extension (id `coolcom`) for both coolcom languages: highlighting, brackets, indents
and outline. Grammar only, no language server.

| Language | Suffixes | Grammar |
|---|---|---|
| Cool (HolyC) | `.cool` `.coolh` (legacy `.HC` `.HH` `.hc` `.hh`) | `project-solomon/tree-sitter-holyc`, pinned in `extension.toml` |
| Warm | `.warm` `.warmh` (legacy Austral `.aum` `.aui`) | `tools/tree-sitter-warm` |

## Install / reinstall

```sh
tools/zed-coolcom/install.sh
```

It generates the Warm parser, builds both wasm grammars (needs the `tree-sitter` CLI; set
`TREE_SITTER=/path/to/tree-sitter` if it is not on `PATH`), removes the old `holyc` extension
from `~/Library/Application Support/Zed/extensions/installed/` and copies this one in as
`installed/coolcom`. Zed reloads it by itself; restart Zed if the languages do not change.
Run it again after editing a `.scm` file, `config.toml` or a grammar.

`tools/tree-sitter-warm/check-repo.sh` parses every `.warm`/`.warmh` in the repo.
