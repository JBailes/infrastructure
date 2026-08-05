# ACK! source patches

Fixes applied to the legacy MUD sources at build time, for defects that the
upstream archive repos have not merged yet.

Each patch is **idempotent** and becomes a **no-op** once upstream carries the
fix, so these can stay in place indefinitely. `01-setup-ack-mud.sh` runs them
from `build_source()` before compiling.

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
