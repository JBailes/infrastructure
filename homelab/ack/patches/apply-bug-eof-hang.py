#!/usr/bin/env python3
"""Fix the infinite loop in bug()'s line-number counter.

THE BUG
-------
assault30 hung on boot, permanently, every time. gdb on the live process:

    #0 bug (str="Fread_string: EOF") at db.c:1751
    #2 _fread_string (...)           at ssm.c:423
    #3 fread_object (...)            at save.c:1515
    #4 load_sobjects (mode=1)        at db.c:1933
    #5 boot_db (...)                 at db.c:391

with rax = 0xffffffff -- getc() returning EOF.

bug() reports which line of the area file went wrong by rewinding and
counting newlines:

    for ( iLine = 0; ftell( fpArea ) < iChar; iLine++ )
    {
        while ( getc( fpArea ) != '\\n' )
            ;
    }

Neither loop checks for EOF:

  * the inner `while` compares against '\\n' only, so at end-of-file getc()
    returns EOF forever and it never terminates;
  * the outer `for` is guarded by ftell() < iChar, and ftell() stops
    advancing at EOF, so it would spin too.

bug() is very often called *because* something hit EOF -- a truncated or
corrupt data file -- which is exactly when the file pointer is already at
the end. So the error reporter deadlocks the process precisely when there
is an error to report. The MUD never finishes boot_db(), never accepts
connections, and systemd sees a perfectly healthy running process.

That is what took assault30 down for six days: a corrupt object save file
turned a logged error into a permanent hang.

THE FIX
-------
Stop both loops at EOF. The line number reported may be short when the
file is truncated, which is fine -- a slightly wrong line number beats a
hung server.

This does NOT repair whatever corrupt data file triggered the EOF; it
makes the failure survivable and logged instead of fatal and silent.

Idempotent: re-running detects the fix and does nothing.
"""

import re
import shutil
import sys
from pathlib import Path

# Matches the loop with whatever bracing/indentation a given repo uses.
LOOP_RE = re.compile(
    r"(?P<indent>[ \t]*)for\s*\(\s*iLine\s*=\s*0;\s*ftell\(\s*fpArea\s*\)\s*<\s*iChar;"
    r"\s*iLine\+\+\s*\)\s*\n"
    r"[ \t]*\{[ \t]*\n"
    r"[ \t]*while\s*\(\s*getc\(\s*fpArea\s*\)\s*!=\s*'\\n'\s*\)\s*\n"
    r"[ \t]*;[ \t]*\n"
    r"[ \t]*\}"
)

TEMPLATE = """{i}/* Both loops must stop at EOF. bug() is usually called *because*
{i}   something hit end-of-file, so the file pointer is already there:
{i}   getc() then returns EOF forever and this counter never terminates,
{i}   hanging the server on boot instead of reporting the error. */
{i}for ( iLine = 0; ftell( fpArea ) < iChar; iLine++ )
{i}{{
{i}    int bugc;
{i}    do
{i}    {{
{i}        bugc = getc( fpArea );
{i}    }}
{i}    while ( bugc != '\\n' && bugc != EOF );
{i}    if ( bugc == EOF )
{i}        break;
{i}}}"""

MARKER = "Both loops must stop at EOF"


def patch(path: Path) -> int:
    text = path.read_text()
    if MARKER in text:
        print(f"  {path.name}: already patched")
        return 0

    matches = list(LOOP_RE.finditer(text))
    if not matches:
        if "getc( fpArea )" in text or "getc(fpArea)" in text:
            raise SystemExit(
                f"ERROR: {path} has a getc(fpArea) loop but not in the expected\n"
                "shape. Inspect it by hand before patching."
            )
        print(f"  {path.name}: no vulnerable loop (not affected)")
        return 0

    # Replace from the end so earlier offsets stay valid.
    for m in reversed(matches):
        text = text[: m.start()] + TEMPLATE.format(i=m.group("indent")) + text[m.end():]

    shutil.copy2(path, path.with_suffix(".c.orig-eof"))
    path.write_text(text)
    print(f"  {path.name}: fixed {len(matches)} loop(s)")
    return len(matches)


def main() -> None:
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "/opt/mud/src/src")
    db = src / "db.c"
    if not db.is_file():
        raise SystemExit(f"ERROR: {db} not found")
    print(f"Patching {src}")
    n = patch(db)
    print("Nothing to do." if n == 0 else f"\nFixed {n} infinite loop(s).")


if __name__ == "__main__":
    main()
