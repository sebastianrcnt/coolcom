#!/usr/bin/env python3
"""Make the shell prelude from the kernel sources (os/Kernel/Kernel.HC and
what it #includes, in order).

The shell JIT-compiles the prelude before the first command line. It holds
the kernel's #defines, classes and unions verbatim, and an `extern` prototype
for every function the kernel defines (assembly `import`s become `extern`
too). In JIT mode `extern` binds a prototype to the system symbol of the same
name, and the shell registers every kernel symbol as one (Shell.HC, from the
table tools/binlink.py puts in the Image), so shell code calls the kernel
directly. Global variables and function bodies are left out.
A function defined twice is an error (HolyC would silently keep the later one).
(#includes are followed, so the prelude sees the same #defines, e.g.
COOLCOM_KERNEL, as the kernel did.)
Usage: mkprelude.py os/Kernel/Kernel.HC > build/ShellPrelude.HH
"""
import pathlib
import re
import sys


def strip_comments(text):
    """Replace comments with spaces, keeping strings, chars and line breaks."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def braces(s):
    """Net brace count of s, ignoring strings and char constants."""
    d, i, n = 0, 0, len(s)
    while i < n:
        c = s[i]
        if c in "\"'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            i = j + 1
            continue
        d += (c == "{") - (c == "}")
        i += 1
    return d


def first_brace(s):
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in "\"'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            i = j + 1
            continue
        if c == "{":
            return i
        i += 1
    return -1


defined = {}
dups = []
var_externs = []  # after everything else (see main)


def process(path, out):
    text = strip_comments(path.read_bytes().decode("latin-1"))
    lines = text.split("\n")
    i = cond = 0
    stmt = ""
    while i < len(lines):
        ln = lines[i]
        i += 1
        if not stmt:
            s = ln.strip()
            if not s:
                continue
            if s.startswith("#"):
                block = [ln]
                while block[-1].rstrip().endswith("\\") and i < len(lines):
                    block.append(lines[i])
                    i += 1
                m = re.match(r'#include\s+"([^"]+)"', s)
                if m:
                    out.append(f"// ---- {m.group(1)} ----")
                    process(path.parent / m.group(1), out)
                else:
                    out.append("\n".join(block))
                if re.match(r"#if", s):
                    cond += 1
                elif s.startswith("#endif"):
                    cond -= 1
                continue
        stmt += ln + "\n"
        b = first_brace(stmt)
        if b < 0:
            if ";" in stmt:
                emit_decl(stmt, out)
                stmt = ""
            continue
        if "=" in stmt[:b] and "(" not in stmt[:b].split("=")[0]:
            # A global with a braced initializer: read to the ';' after the braces.
            while (braces(stmt) > 0 or not stmt.rstrip().endswith(";")) and i < len(lines):
                stmt += lines[i] + "\n"
                i += 1
            emit_vars(stmt, out)
            stmt = ""
            continue
        # A braced statement: read to its closing brace (and the ';' after a class).
        while braces(stmt) > 0 and i < len(lines):
            stmt += lines[i] + "\n"
            i += 1
        head = stmt[:b]
        if re.match(r"\s*(public\s+)?(\w+\s+)?(class|union)\b", head) and "(" not in head:
            while not stmt.rstrip().endswith(";") and i < len(lines):
                stmt += lines[i] + "\n"
                i += 1
            out.append(stmt.rstrip())
        elif head.rstrip().endswith(")") and "=" not in head.split("(")[0]:
            proto = re.sub(r"^public\s+", "", " ".join(head.split()))
            name = re.search(r"(\w+)\s*\($", proto.split("(")[0] + "(").group(1)
            if not cond:  # (definitions under #if are left to the preprocessor)
                if name in defined and not ("Runtime" in defined[name] and "Runtime" in str(path)):
                    # HolyC would let the later one silently replace the earlier one
                    dups.append(f"{name} ({defined[name]} and {path})")
                defined[name] = str(path)
            out.append("extern " + proto + ";")
        stmt = ""


def emit_decl(stmt, out):
    s = " ".join(stmt.split())
    if re.match(r"(extern|import)\s+class\b", s):
        out.append(s)
    elif s.startswith("import "):
        out.append("extern " + s[len("import "):])
    else:
        emit_vars(stmt, out)


def emit_vars(stmt, out):
    """A global variable declaration: an `extern` per variable (the shell binds
    it to the kernel symbol of the same name). Initializers are dropped;
    function pointers and anything unusual are left out."""
    s = re.sub(r'"(\\.|[^"\\])*"|\'(\\.|[^\'\\])*\'', "0", stmt)
    while "{" in s:
        s2 = re.sub(r"\{[^{}]*\}", "0", s)
        if s2 == s:
            return
        s = s2
    s = " ".join(s.split()).rstrip(";").strip()
    m = re.match(r"(public\s+)?([A-Za-z_]\w*)\s+(.*)$", s)
    if not m or m.group(2) in ("extern", "_extern", "import", "_import", "_intern", "return", "goto",
                                "class", "union", "if", "while", "for", "do", "switch", "no_warn"):
        return
    typ, parts, depth, cur = m.group(2), [], 0, ""
    for ch in m.group(3):
        depth += ch in "([" and 1 or ch in ")]" and -1 or 0
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    for d in parts:
        d = d.split("=")[0].strip()
        if re.fullmatch(r"\**\s*[A-Za-z_]\w*(\s*\[[^\]]*\])*", d):
            var_externs.append(f"extern {typ} {d};")


def main():
    entry = pathlib.Path(sys.argv[1])
    out = ["// Shell prelude, generated by tools/mkprelude.py from the kernel sources."]
    process(entry, out)
    out.append("// ---- global variables ----")
    out += var_externs
    if dups:
        sys.exit("mkprelude: defined twice (HolyC keeps the later one silently):\n  " + "\n  ".join(dups))
    sys.stdout.buffer.write(("\n".join(out) + "\n").encode("latin-1"))


main()
