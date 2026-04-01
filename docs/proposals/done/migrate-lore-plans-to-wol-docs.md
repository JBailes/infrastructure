# Proposal: Migrate acktng/docs/lore and acktng/docs/plans to wol-docs

## Status
Complete.

## Problem

Game lore and area plans have been stored in `acktng/docs/lore/` and `acktng/docs/plans/`. Since WOL is replacing acktng as the primary game server, these world-building documents belong in `wol-docs/` -- the canonical documentation repository for the WOL ecosystem.

## Approach

1. Copy `acktng/docs/lore/` → `wol-docs/lore/`
2. Copy `acktng/docs/plans/` → `wol-docs/plans/`
3. Delete both directories from acktng
4. Update `CLAUDE.md` to reflect new lore and proposal locations
5. Update project memory references

## Affected Repositories

- `wol-docs` -- receives lore/ and plans/
- `acktng` -- lore/ and plans/ removed
- `aicli` -- CLAUDE.md updated

## Trade-offs

- Git history for the files does not carry over to wol-docs. History remains in acktng for reference.
- Existing acktng proposals (`acktng/docs/proposals/`) remain in acktng -- they are acktng-specific.

## Not Included

- `acktng/docs/proposals/` -- stays in acktng (acktng-specific implementation history)
- Other `acktng/docs/` files (specs, maps, license files) -- acktng-specific technical docs
