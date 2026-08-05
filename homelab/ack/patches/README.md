# ACK! source patches

Fixes applied to the legacy MUD sources at build time, for defects that the
upstream archive repos have not merged yet.

Each patch is **idempotent** and becomes a **no-op** once upstream carries the
fix, so these can stay in place indefinitely. `01-setup-ack-mud.sh` runs them
from `build_source()` before compiling.

## apply-bug-eof-hang.py

Fixes a permanent hang on boot when a data file is truncated.

### Symptom

`assault30` hung during boot, every time, at `Loading ../data/objects.lst`.
Process alive, socket bound, accept queue filling and never drained — systemd
reported the unit `active` throughout. It had been down for six days before
anyone noticed, and re-hung immediately each time the watchdog restarted it.

### Cause

`bug()` reports which line of a data file went wrong by rewinding and counting
newlines:

```c
for ( iLine = 0; ftell( fpArea ) < iChar; iLine++ )
{
    while ( getc( fpArea ) != '\n' )   /* never checks EOF */
        ;
}
```

Neither loop checks for EOF. The inner `while` compares only against `'\n'`,
so at end-of-file `getc()` returns `EOF` forever and it never terminates. The
outer `for` is guarded by `ftell() < iChar`, and `ftell()` stops advancing at
EOF, so it would spin as well.

`bug()` is very often called *because* something hit EOF — a truncated file —
which is exactly when the file pointer is already at the end. **The error
reporter deadlocks the process precisely when there is an error to report.**

Confirmed with gdb on the live hung process:

```
#0 bug (str="Fread_string: EOF")  at db.c:1751
#2 _fread_string (...)            at ssm.c:423
#3 fread_object (...)             at save.c:1515
#4 load_sobjects (mode=1)         at db.c:1933
#5 boot_db (...)                  at db.c:391
```

with `rax = 0xffffffff` — `getc()` returning `EOF`.

### Fix

Stop both loops at EOF. The reported line number may be short on a truncated
file; a slightly wrong line number beats a hung server.

This does **not** repair the corrupt data file — it makes the failure logged
and survivable instead of silent and fatal. With the fix applied, assault30
reported the real fault immediately:

```
[*****] FILE: ../data/objects.lst LINE: 1592
[*****] BUG: Fread_string: EOF
```

`objects.lst` had a final record truncated mid-string (no `~`, no trailing
newline) at exactly 196 KiB — a write cut off at a block boundary. Dropping
the incomplete trailing record brought the MUD back.

### Affected repos

Present in **5 of 6** archive codebases: `ackmud431`, `ackmud42`, `ackmud41`,
`Assault3.0`, `ACKFUSS`. Only `acktng` is clean. Two occurrences per `db.c`.

---

## apply-shield-wearoff-segv.py

Fixes a SIGSEGV on magic-shield expiry.

### Symptom

`ack42` died with SIGSEGV every ~12 minutes for weeks — 739 restarts, ~5/hour.
systemd reported the service as healthy between crashes, so nothing surfaced it.

### Cause

`handler.c` (~line 654) in `affect_remove()`:

```c
sprintf( buf1, this_shield->wearoff_room );
sprintf( buf2, this_shield->wearoff_self );
```

Two defects in those two lines:

1. **NULL dereference — the actual crash.** `GET_FREE()` does
   `memset(item, 0, sizeof(*item))`, so a recycled shield starts with
   `wearoff_room`/`wearoff_self` set to NULL. Of the five shield-creation
   sites in `magic3.c`, only `spell_fireshield` and `spell_iceshield`
   populate them — `spell_shockshield`, `spell_shadowshield` and
   `spell_thoughtshield` do not. When one of those expires,
   `char_update() -> affect_remove() -> sprintf(buf, NULL)` segfaults.
   The 12-minute period is simply the shield duration.

2. **Format-string bug — latent.** The message is passed as sprintf's
   *format* argument, so a `%` in the text would consume a vararg that was
   never pushed. Harmless today only because the strings contain no `%`.

Diagnosed with gdb against the live process (the binaries ship with
`-g3`, unstripped):

```
#3  sprintf ()
#4  affect_remove (...) at handler.c:654
#5  char_update () at update.c:1341
```

`rdi=0x0` at the fault confirmed the NULL argument.

### Fix

- `handler.c` — copy with `snprintf(..., "%s", ...)`, NULL-guard, and skip
  `act()` on an empty message. Makes the crash impossible regardless of which
  shields populate messages, and removes the format-string hazard. **ACKFUSS
  already uses this safer form**, which is what suggested the fix.
- `magic3.c` — populate wearoff messages for shock/shadow/thought shields so
  they expire with a message like fire and ice do, rather than silently.

### Affected repos

| Repo | handler.c bug | magic3.c gaps | Was crashing |
|------|---------------|---------------|--------------|
| `ackmud42` | yes | yes | **yes** — 739 restarts |
| `ackmud41` | yes | yes | no (latent) |
| `ackmud431` | yes | no | no (latent) |
| `ACKFUSS` | already fixed | n/a | no |
| `acktng`, `Assault3.0` | no shield code | n/a | no |

### Upstream

Submitted as PRs to the `ackmudhistoricalarchive` org. Once merged, this
patch detects the fix is present and does nothing.

### Usage

```bash
python3 apply-shield-wearoff-segv.py /path/to/src   # dir containing handler.c
```

Writes `.orig` backups beside each file it changes. Refuses to run rather than
guessing if the source does not match what it expects.
