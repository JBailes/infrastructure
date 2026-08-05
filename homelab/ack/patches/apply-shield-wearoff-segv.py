#!/usr/bin/env python3
"""Fix the shield-expiry SIGSEGV in the legacy ACK MUD sources.

THE BUG
-------
ack42 segfaulted every ~12 minutes for weeks. Backtrace:

    #3 sprintf ()
    #4 affect_remove (...) at handler.c:654
    #5 char_update () at update.c:1341

handler.c:654 reads:

    sprintf( buf1, this_shield->wearoff_room );

Two defects in one line:

  1. NULL dereference (the actual crash). GET_FREE() memsets a recycled
     shield to zero, so wearoff_room/wearoff_self start life as NULL. Of the
     five shield-creation sites in magic3.c, only two (FLAME at 422, ICE at
     478) ever populate them -- SHOCK, SHADOW and THOUGHT never do. When one
     of those shields expires, char_update -> affect_remove -> sprintf(buf,
     NULL) -> SIGSEGV. The 12-minute period is just the shield duration.

  2. Format-string bug (latent). The message is passed as sprintf's *format*
     argument, so any '%' in the text would consume a vararg that was never
     pushed. Harmless today only because the hardcoded strings contain no '%'.

THE FIX
-------
  - handler.c: copy with snprintf("%s", ...), guard NULL, skip empty messages.
    This makes the crash impossible regardless of which shields set messages.
  - magic3.c: populate wearoff messages for the three shields that omit them,
    so those shields expire with a message like the other two instead of
    silently.

Idempotent: re-running detects the fix is already present and does nothing.
"""

import re
import shutil
import sys
from pathlib import Path

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else "/opt/mud/src/src")

# Indentation differs between the archive repos (ackmud42 uses 8 spaces,
# ackmud431 uses 9), so match structurally and reuse whatever indent is there.
HANDLER_RE = re.compile(
    r"(?P<indent>[ \t]*)sprintf\(\s*buf1,\s*this_shield->wearoff_room\s*\);[ \t]*\n"
    r"[ \t]*sprintf\(\s*buf2,\s*this_shield->wearoff_self\s*\);[ \t]*\n"
    r"[ \t]*act\(\s*buf1,\s*ch,\s*NULL,\s*NULL,\s*TO_ROOM\s*\);[ \t]*\n"
    r"[ \t]*act\(\s*buf2,\s*ch,\s*NULL,\s*NULL,\s*TO_CHAR\s*\);"
)

HANDLER_TEMPLATE = """{i}/* These are message strings, NOT format strings. Passing them
{i}   straight to sprintf crashes when they are NULL (a recycled shield
{i}   is memset to zero by GET_FREE, and several shield types never set
{i}   them) and would misparse any '%' in the text. */
{i}snprintf( buf1, sizeof( buf1 ), "%s",
{i}          this_shield->wearoff_room != NULL
{i}            ? this_shield->wearoff_room : "" );
{i}snprintf( buf2, sizeof( buf2 ), "%s",
{i}          this_shield->wearoff_self != NULL
{i}            ? this_shield->wearoff_self : "" );
{i}if ( buf1[0] != '\\0' )
{i}   act( buf1, ch, NULL, NULL, TO_ROOM );
{i}if ( buf2[0] != '\\0' )
{i}   act( buf2, ch, NULL, NULL, TO_CHAR );"""

# Shield name line -> (wearoff_room, wearoff_self). Styled after the existing
# FLAME/ICE messages in magic3.c.
WEAROFF = {
    '"@@lSHOCK@@N"': (
        "@@N$n's @@lshield@@N @@yFIZZLES OUT@@N!!!!!",
        "@@NYour @@lshield@@N @@yFIZZLES OUT@@N!!!!!",
    ),
    '"@@dSHADOW@@N"': (
        "@@N$n's @@dshield@@N @@yFADES AWAY@@N!!!!!",
        "@@NYour @@dshield@@N @@yFADES AWAY@@N!!!!!",
    ),
    '"@@mTHOUGHT@@N"': (
        "@@N$n's @@mshield@@N @@yDISSIPATES@@N!!!!!",
        "@@NYour @@mshield@@N @@yDISSIPATES@@N!!!!!",
    ),
}

changed = []


def patch_handler(path: Path) -> None:
    text = path.read_text()
    if "NOT format strings" in text:
        print("  handler.c: already patched")
        return
    match = HANDLER_RE.search(text)
    if match is None:
        if "sprintf( buf1, this_shield->wearoff_room )" not in text:
            print("  handler.c: no vulnerable sprintf block found (not affected)")
            return
        raise SystemExit(
            f"ERROR: {path} contains the sprintf call but not in the expected\n"
            "surrounding block. Inspect it by hand before patching."
        )
    replacement = HANDLER_TEMPLATE.format(i=match.group("indent"))
    shutil.copy2(path, path.with_suffix(".c.orig"))
    path.write_text(text[: match.start()] + replacement + text[match.end():])
    changed.append(str(path))
    print("  handler.c: patched sprintf -> guarded snprintf")


def patch_magic3(path: Path) -> None:
    text = path.read_text()
    original = text
    for name, (room, self_) in WEAROFF.items():
        # Consume any trailing whitespace on the anchor line too, otherwise
        # the original line's trailing tabs end up stranded after the lines
        # we insert.
        anchor_re = re.compile(
            r"(?P<indent>[ \t]*)shield->name\s*=\s*str_dup\(\s*"
            + re.escape(name)
            + r"\s*\);[ \t]*"
        )
        match = anchor_re.search(text)
        if match is None:
            print(f"  magic3.c: no {name} shield in this codebase, skipping")
            continue
        # Already populated for this shield?
        window = text[match.start(): match.start() + 1400]
        if "wearoff_room" in window:
            print(f"  magic3.c: {name} already sets wearoff, skipping")
            continue
        indent = match.group("indent")
        addition = (
            f'{indent}shield->name = str_dup( {name} );\n'
            f"{indent}/* Without these the shield expires into sprintf(buf, NULL). */\n"
            f'{indent}shield->wearoff_room = str_dup( "{room}" );\n'
            f'{indent}shield->wearoff_self = str_dup( "{self_}" );'
        )
        text = text[: match.start()] + addition + text[match.end():]
        print(f"  magic3.c: added wearoff messages for {name}")

    if text != original:
        shutil.copy2(path, path.with_suffix(".c.orig"))
        path.write_text(text)
        changed.append(str(path))


def main() -> None:
    handler = SRC / "handler.c"
    magic3 = SRC / "magic3.c"
    if not handler.is_file():
        raise SystemExit(f"ERROR: {handler} not found")

    print(f"Patching {SRC}")
    patch_handler(handler)
    # Not every archive repo has magic3.c; the handler.c guard is what
    # actually prevents the crash, so a missing magic3.c is not fatal.
    if magic3.is_file():
        patch_magic3(magic3)
    else:
        print("  magic3.c: not present in this codebase, skipping")

    if changed:
        print(f"\nModified: {', '.join(changed)}  (.orig backups written)")
    else:
        print("\nNothing to do -- already patched.")


if __name__ == "__main__":
    main()
