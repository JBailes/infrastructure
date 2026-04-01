# Proposal: Move Skill/Spell Definitions to Database with Lua Scripting

**Status:** Rejected
**Date:** 2026-03-23 (revised 2026-03-24)
**Repos affected:** acktng, tngdb

---

## Problem

All skill and spell metadata and logic is compiled directly into the game binary:

- `src/spells/spell_table_data.c` (~3087 lines) -- metadata for ~200+ spells
- `src/skills/skill_table_data.c` (~3358 lines) -- metadata for ~300+ skills
- `src/spells/spell_*.c` -- 246 individual C functions, one per spell
- `src/skills/do_*.c` -- 109 individual C files, one per skill
- `src/ai/spec_*.c` -- 120+ NPC special procedure functions, one per behavior

Adding, removing, or tuning any skill, spell, or NPC behavior requires editing C source and recompiling the game. The web frontend and tngdb have no access to skill/spell data at all.

The previous revision of this proposal addressed the metadata problem by moving definitions to PostgreSQL, and addressed the logic problem with a fixed taxonomy of ~15 composable effect types (`DAMAGE`, `HEAL`, `APPLY_AFFECT`, etc.) stored as JSONB parameter blobs. That approach had two weaknesses:

1. **Rigid effect taxonomy.** Any spell that didn't decompose into the predefined effect types required a `CUSTOM` fallback to a compiled C function. Eight spells were already identified as requiring this, and any future spell with novel mechanics would also need new C code -- defeating the purpose of data-driving.

2. **Formula DSL limitations.** The proposed formula mini-language (`"5d8+level"`, `"level/4"`) was too simple for spells that reference class levels, combo counts, shield pools, or conditional branches. Extending the DSL toward those features would amount to inventing a bad programming language.

This revised proposal replaces the effect-composition/JSONB approach with **embedded Lua scripting**. Spell and skill logic is written in Lua scripts that call into a C API exposing game engine primitives. The same Lua engine also provides a future path for NPC AI scripting, replacing the 120+ compiled `spec_*.c` files.

---

## Goal

1. Move skill/spell **metadata** (name, per-class levels, mana cost, beats, etc.) from compiled C tables into PostgreSQL -- unchanged from the original proposal.

2. Move skill/spell **logic** from compiled C functions into **Lua scripts stored in PostgreSQL** (loaded into the Lua VM at boot, reloadable at runtime). Each spell or skill that currently has a `spell_*.c` or `do_*.c` file gets a corresponding Lua script stored as a TEXT column in the `skills` table.

3. Embed a **Lua 5.4 interpreter** in the game server, with a sandboxed C API that exposes game primitives (damage, healing, affects, object manipulation, character queries, etc.) to Lua scripts.

4. Establish the Lua engine as the **shared scripting layer** for spells, skills, and (in a future phase) NPC AI -- replacing `spec_*.c` special procedures.

5. Expose skill/spell metadata via **tngdb API endpoints** for the web frontend.

---

## Architecture Overview

```
                    +-----------------------+
                    |      PostgreSQL       |
                    |    skills table       |
                    |  - metadata (name,    |
                    |    levels, mana, etc) |
                    |  - script_source      |
                    |    (Lua source TEXT)   |
                    |  - lua_libraries      |
                    |    (shared modules)    |
                    +-----------+-----------+
                                |
                      boot_db() loads metadata
                      + compiles Lua source
                                |
                                v
   +-------------------+    skill_table[]    +-------------------+
   |   magic.c         |  (runtime array)    |   skills.c        |
   |  cast/obj_cast    +---> lookup sn +---->+  can_use_skill    |
   |  mana_cost()      |                     |  energy_cost()    |
   +--------+----------+                     +--------+----------+
            |                                         |
            |  spell_fun(sn,level,ch,vo,obj)          |  do_fun(ch,argument)
            |                                         |
            v                                         v
   +----------------------------------------------------------+
   |                  Lua VM  (lua_State *)                    |
   |                                                           |
   |  [compiled bytecode cached per sn]                        |
   |  fireball -> execute(ctx)    bash -> execute(ctx)         |
   |  animate  -> execute(ctx)    chakra -> execute(ctx)       |
   |  lib/common (shared module)  lib/damage_tables (shared)   |
   +---------------------+------------------------------------+
                          |
                 calls C API functions
                          |
                          v
   +----------------------------------------------------------+
   |               C API  (src/lua/lua_api.c)                  |
   |                                                           |
   |  mud.damage()      mud.heal()       mud.send()            |
   |  mud.apply_affect() mud.remove_affect()  mud.act()        |
   |  mud.war_attack()  mud.saves_spell()  mud.dice()          |
   |  mud.create_object() mud.teleport() mud.get_room()        |
   |  char.hp  char.level  char.class_level[X]  char.mana     |
   |  ...                                                      |
   +----------------------------------------------------------+
```

**Data flow for casting a spell (e.g. `cast fireball goblin`):**

1. `magic.c:do_cast()` resolves the spell name to `sn`, checks mana, resolves target -- all unchanged.
2. Instead of calling a compiled `spell_fireball()` C function, it calls `lua_spell_execute(sn, level, ch, vo, obj)`.
3. The Lua dispatcher retrieves the precompiled bytecode for `sn` (loaded from `skills.script_source` at boot) and calls its `execute()` function, passing a Lua table with the spell context (sn, level, caster, victim, obj).
4. The Lua script calls C API functions like `mud.damage()`, `mud.saves_spell()`, `mud.send()` which are thin wrappers around existing C engine functions.
5. Control returns to `magic.c`, which deducts mana on success -- unchanged.

**Data flow for using a skill (e.g. `bash goblin`):**

1. `interp.c` dispatches to `lua_skill_execute(gsn_bash, ch, argument)`.
2. The Lua script for bash calls `mud.can_use_skill()`, `mud.war_attack()`, `mud.wait_state()`, etc.
3. Control returns to the interpreter.

### Why Lua

| Criterion | Lua | Custom DSL/JSONB | Python/JS |
|---|---|---|---|
| Embedding size | ~300 KB, zero dependencies | N/A | Huge runtime |
| Speed | LuaJIT-competitive; C API calls are direct | Interpreted JSON walks | Slower, GC pauses |
| MUD heritage | Industry standard (CoffeeMUD, MudOS forks, NeverWinter Nights, WoW) | Novel, untested | Rare in MUDs |
| Expressiveness | Full language: loops, conditionals, tables, closures | Limited to predefined effect types | Full but overkill |
| Sandboxing | Remove `io`, `os`, `loadfile`; whitelist API | Inherently sandboxed | Difficult to sandbox |
| Learning curve | Simple syntax, well-documented, familiar to game designers | Custom, must be learned | Familiar but heavy |
| Hot reload | `UPDATE skills SET script_source=...` + `luareload` in-game, no recompile | DB UPDATE + reload | Requires restart |

---

## Database Schema

### `skills` table

Holds metadata -- unchanged from the original proposal. This is the single source of truth for skill/spell definitions, loaded into `skill_table[]` at boot.

```sql
CREATE TABLE skills (
    sn            SMALLINT    PRIMARY KEY,        -- stable index, matches current array position
    name          TEXT        NOT NULL UNIQUE,
    flag2         SMALLINT    NOT NULL DEFAULT 1,  -- 1=NORM
    target        SMALLINT    NOT NULL DEFAULT 0,
    min_position  SMALLINT    NOT NULL DEFAULT 0,
    gsn_name      TEXT        NOT NULL DEFAULT '',  -- C gsn variable name; '' if none
    slot          SMALLINT    NOT NULL DEFAULT 0,
    min_mana      SMALLINT    NOT NULL DEFAULT 0,
    beats         SMALLINT    NOT NULL DEFAULT 0,
    can_learn     BOOLEAN     NOT NULL DEFAULT TRUE,
    noun_damage   TEXT        NOT NULL DEFAULT '',
    msg_off       TEXT        NOT NULL DEFAULT '',
    room_off      TEXT        NOT NULL DEFAULT '',
    growth        SMALLINT    NOT NULL DEFAULT 0,
    class_levels  JSONB       NOT NULL DEFAULT '{}', -- {"MAG": 5, "CLE": 10, ...}; absent = NO_USE
    script_source TEXT        NOT NULL DEFAULT ''     -- Lua source code for this skill/spell
);
```

The `script_source` column contains the full Lua source code that implements this skill/spell. At boot, each non-empty `script_source` is compiled to bytecode and cached in the Lua VM. An empty string means no script (skill is passive or uses a C fallback during migration).

The `skill_effects` table from the original proposal is **removed entirely** -- Lua scripts replace effect composition.

### `lua_libraries` table

Shared Lua modules (common damage tables, utility functions, standard patterns) are stored in a separate table. Scripts access them via a controlled `require()` that only loads from this table.

```sql
CREATE TABLE lua_libraries (
    name          TEXT        PRIMARY KEY,         -- module name, e.g. "common", "damage_tables"
    source        TEXT        NOT NULL,            -- Lua source code
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Example usage in a spell script:
```lua
local common = require("common")        -- loads from lua_libraries where name='common'
local tables = require("damage_tables")  -- loads from lua_libraries where name='damage_tables'
```

The controlled `require()` is registered in the Lua VM at init. It searches only `lua_libraries` -- never the filesystem. This maintains sandboxing while enabling code reuse across scripts.

### No schema changes for cooldowns or learned percentages

`cooldown[MAX_SKILL]` and `learned[MAX_SKILL]` remain as C arrays on `CHAR_DATA` / `PC_DATA` respectively, indexed by `sn`. These are per-character runtime state, not skill definitions. They are unchanged by this proposal:

- **`learned[sn]`** -- Player's proficiency percentage (0-100) in skill `sn`. Set by `raise_skill()`, checked by `skill_success()`. Lua scripts read this via `char:learned(sn)` but never write it directly -- they call `mud.raise_skill(ch, sn)` which delegates to the existing C function.
- **`cooldown[sn]`** -- Ticks remaining before skill `sn` can be used again. Set by the Lua script via `mud.set_cooldown(ch, sn, ticks)`, checked by `can_use_skill()` in C before the Lua script is ever invoked.
- **`WAIT_STATE`** -- Combat pulse delay after using a skill. Set by the Lua script via `mud.wait_state(ch, beats)`, using the value from `skill_table[sn].beats` (passed to the script via `ctx.beats`).

---

## Lua C API

The C API exposed to Lua scripts is organized into modules. Each module is a set of C functions registered into the Lua VM at boot. Scripts access them as `mud.damage()`, `char:get_hp()`, etc.

### `mud` module -- Game engine primitives

These are thin wrappers around existing C functions. They do not introduce new game mechanics -- they expose what already exists.

#### Combat

| Lua function | C function it wraps | Description |
|---|---|---|
| `mud.damage(ch, victim, dam, sn, element, show)` | `sp_damage()` / `calculate_damage()` | Deal damage with element and skill attribution |
| `mud.damage_from_obj(obj, ch, victim, dam, element, sn, show)` | `sp_damage()` | Damage from an object-cast spell |
| `mud.war_attack(ch, victim, gsn)` | `war_attack()` | Standard melee skill attack (handles hit check, damage calc, combo) |
| `mud.saves_spell(level, victim)` | `saves_spell()` | Returns true if victim saves vs spell |
| `mud.is_safe(ch, victim)` | `is_safe()` | PK/safe-room check |
| `mud.can_hit_skill(ch, victim, gsn)` | `can_hit_skill()` | Skill hit check (incorporates learned%) |

#### Healing and Resources

| Lua function | C function | Description |
|---|---|---|
| `mud.heal(victim, amount)` | `victim->hit = UMIN(victim->hit + amount, get_max_hp(victim)); update_pos(victim)` | Heal HP, capped at max |
| `mud.heal_mana(victim, amount)` | direct `victim->mana` manipulation | Restore mana |
| `mud.heal_move(victim, amount)` | direct `victim->move` manipulation | Restore movement |
| `mud.class_heal(ch, victim, base, sn, class)` | `class_heal_character()` | Class-scaled healing |

#### Affects

| Lua function | C function | Description |
|---|---|---|
| `mud.apply_affect(victim, af_table)` | `affect_to_char()` | Apply an affect (type, duration, location, modifier, bitvector, duration_type) |
| `mud.affect_join(victim, af_table)` | `affect_join()` | Apply or stack an affect |
| `mud.affect_strip(victim, sn)` | `affect_strip()` | Remove all affects of type `sn` |
| `mud.remove_affect_flag(victim, flag)` | `affect_strip()` by bitvector | Remove affects with specific AFF_* flag |
| `mud.is_affected(victim, sn)` | `is_affected()` | Check if victim has affect of type `sn` |
| `mud.has_affect_flag(victim, flag)` | `IS_AFFECTED()` macro | Check AFF_* bitvector |
| `mud.apply_room_affect(room, ra_table)` | `affect_to_room()` | Apply a room affect |

#### Objects and World

| Lua function | C function | Description |
|---|---|---|
| `mud.create_object(vnum, level)` | `create_object()` | Create an object instance from index |
| `mud.obj_to_room(obj, room)` | `obj_to_room()` | Place object in room |
| `mud.obj_to_char(obj, ch)` | `obj_to_char()` | Give object to character |
| `mud.obj_from_obj(obj)` | `obj_from_obj()` | Remove object from its containing object |
| `mud.get_obj_carry(ch, name)` | `get_obj_carry()` | Find object in character's inventory |
| `mud.get_obj_room(room, name)` | `get_obj_list()` on `room->contents` | Find object in a room by name |
| `mud.get_obj_contents(container)` | iterate `container->first_content` | Return table of objects inside a container/corpse |
| `mud.extract_obj(obj)` | `extract_obj()` | Remove object from world |
| `mud.get_room(vnum)` | `get_room_index()` | Look up room by vnum |
| `mud.transfer(ch, room)` | `char_from_room()` + `char_to_room()` | Move character to room |
| `mud.chars_in_room(room)` | iterate `room->first_person` | Return table of all characters in a room |
| `mud.interpret(ch, command)` | `interpret()` | Execute a game command as character (e.g. `"wear all"`) -- see reentrancy note in Sandboxing |

#### Characters and Followers

| Lua function | C function | Description |
|---|---|---|
| `mud.create_mobile(vnum)` | `create_mobile()` | Create NPC instance from index |
| `mud.char_to_room(mob, room)` | `char_to_room()` | Place character in room |
| `mud.add_follower(mob, master)` | `add_follower()` | Make mob follow master |
| `mud.stop_follower(mob)` | `stop_follower()` | Remove follower |
| `mud.extract_char(mob, pull)` | `extract_char()` | Remove character from world |
| `mud.set_mob_level(mob, level)` | direct `mob->level = level` | Set NPC level; NPCs only -- player level is immutable from Lua |
| `mud.set_mob_max_hp(mob, hp)` | direct `mob->max_hit = hp` | Set NPC max HP; NPCs only |

#### Output and Communication

| Lua function | C function | Description |
|---|---|---|
| `mud.send(ch, text)` | `send_to_char()` | Send colored text to character |
| `mud.act(format, ch, arg1, arg2, target)` | `act()` | Send formatted action message |
| `mud.echo_room(room, text)` | `send_to_room()` | Send text to all in room |

#### Skill System

| Lua function | C function | Description |
|---|---|---|
| `mud.raise_skill(ch, sn)` | `raise_skill()` | Increase learned% on successful use |
| `mud.wait_state(ch, beats)` | `WAIT_STATE()` macro | Set combat delay |
| `mud.set_cooldown(ch, sn, ticks)` | direct `ch->cooldown[sn] = ticks` | Set skill cooldown |
| `mud.can_use_skill(ch, sn)` | `can_use_skill()` | Check if skill is available (cooldown, level, etc.) |
| `mud.subtract_energy(ch, gsn)` | `subtract_energy_cost()` | Deduct move cost for physical skills |
| `mud.mana_cost(ch, sn)` | `mana_cost()` | Calculate mana cost for a spell |
| `mud.skill_success(ch, sn)` | `skill_success()` | Roll against learned% for skill check |

#### Randomness and Utility

| Lua function | C function | Description |
|---|---|---|
| `mud.dice(n, m)` | `dice()` | Roll NdM |
| `mud.number_range(lo, hi)` | `number_range()` | Random integer in range |
| `mud.number_percent()` | `number_percent()` | Random 1-100 |
| `mud.UMIN(a, b)` | `UMIN()` | Integer minimum |
| `mud.UMAX(a, b)` | `UMAX()` | Integer maximum |

#### Combo System

| Lua function | C function | Description |
|---|---|---|
| `mud.combo(ch, victim, gsn)` | `combo()` | Register hit in combo chain |
| `mud.get_combo_count(ch)` | `get_combo_count()` | Current combo length |
| `mud.reset_combo(ch)` | `reset_combo()` | Clear combo chain |

#### Shield System

| Lua function | C function | Description |
|---|---|---|
| `mud.is_shielded(ch, type)` | `is_shielded()` | Check for magic shield |
| `mud.add_shield(ch, shield_table)` | shield LINK code | Add magic shield to character |
| `mud.remove_shield(ch, type)` | shield UNLINK code | Remove magic shield |

### `char` userdata -- Character properties

Character pointers (`CHAR_DATA *`) are exposed as Lua userdata with read-only property access via `__index` metamethods:

```lua
-- Read-only properties (examples)
ch:get_hp()              -- ch->hit
ch:get_max_hp()          -- get_max_hp(ch)
ch:get_mana()            -- ch->mana
ch:get_max_mana()        -- ch->max_mana
ch:get_move()            -- ch->move
ch:get_level()           -- ch->level
ch:get_class_level(cls)  -- ch->class_level[cls]
ch:get_alignment()       -- ch->alignment
ch:get_gold()            -- ch->gold
ch:get_name()            -- ch->name
ch:get_room()            -- ch->in_room (returns room userdata)
ch:get_fighting()        -- ch->fighting (returns char userdata or nil)
ch:get_position()        -- ch->position
ch:get_str()             -- get_curr_str(ch)
ch:get_dex()             -- get_curr_dex(ch)
ch:get_wis()             -- get_curr_wis(ch)
ch:get_int()             -- get_curr_int(ch)
ch:get_con()             -- get_curr_con(ch)
ch:get_chi()             -- get_chi(ch)
ch:is_npc()              -- IS_NPC(ch)
ch:is_affected(sn)       -- is_affected(ch, sn)
ch:learned(sn)           -- ch->pcdata->learned[sn] (0 for NPCs)
ch:cooldown(sn)          -- ch->cooldown[sn]

-- Mutable properties (via set functions, not direct assignment)
ch:set_hp(val)           -- ch->hit = val; update_pos(ch)
ch:set_mana(val)         -- ch->mana = val
ch:set_move(val)         -- ch->move = val
ch:set_alignment(val)    -- ch->alignment = val
ch:set_gold(val)         -- ch->gold = val
ch:set_position(val)     -- ch->position = val
```

Mutable setters are restricted to values that spell/skill scripts legitimately need to modify. Structural fields (name, level, class, room) are changed only through `mud.*` functions that enforce game rules. NPC-only structural setters (`mud.set_mob_level`, `mud.set_mob_max_hp`) are in the `mud` module and assert `IS_NPC(mob)` before writing.

### Constants

Game constants are pre-loaded into the Lua VM as read-only tables:

```lua
ELE.FIRE            -- ELE_FIRE
ELE.LIGHTNING       -- ELE_LIGHTNING
ELE.HOLY            -- ELE_HOLY
-- etc.

AFF.BLIND           -- AFF_BLIND
AFF.POISON          -- AFF_POISON
AFF.SANCTUARY       -- AFF_SANCTUARY
-- etc.

APPLY.AC            -- APPLY_AC
APPLY.HITROLL       -- APPLY_HITROLL
APPLY.DAMROLL       -- APPLY_DAMROLL
APPLY.DOT           -- APPLY_DOT
-- etc.

POS.STANDING        -- POS_STANDING
POS.FIGHTING        -- POS_FIGHTING
-- etc.

TAR.CHAR_OFFENSIVE  -- TAR_CHAR_OFFENSIVE
TAR.CHAR_DEFENSIVE  -- TAR_CHAR_DEFENSIVE
-- etc.

CLASS.MAG           -- CLASS_MAG
CLASS.CLE           -- CLASS_CLE
CLASS.WAR           -- CLASS_WAR
CLASS.MON           -- CLASS_MON
-- etc.

DURATION.HOUR       -- DURATION_HOUR
DURATION.ROUND      -- DURATION_ROUND
```

---

## Example Lua Scripts

These examples show how existing C spell/skill functions translate to Lua. Each script exports an `execute()` function that receives a context table.

### Simple damage spell: Fireball

Current C (`src/spells/spell_fireball.c`, ~50 lines):
```c
bool spell_fireball(int sn, int level, CHAR_DATA *ch, void *vo, OBJ_DATA *obj) {
    static const sh_int dam_each[] = { 0, 0, ..., 130 };
    CHAR_DATA *victim = (CHAR_DATA *)vo;
    level = UMIN(level, sizeof(dam_each)/sizeof(dam_each[0]) - 1);
    int dam = number_range(dam_each[level]/2, dam_each[level]*2);
    if (saves_spell(level, victim)) dam /= 2;
    sp_damage(obj, ch, victim, dam, ELE_FIRE, sn, TRUE);
    return TRUE;
}
```

Lua equivalent (stored in `skills.script_source` where `name = 'fireball'`):
```lua
local dam_each = {
    [0]=0, 0, 0, 0, 0, 0, 0, 0, 0, 0,             -- 0-9
    0, 0, 0, 0, 0, 30, 35, 40, 45, 50,             -- 10-19
    55, 60, 65, 70, 75, 80, 82, 84, 86, 88,        -- 20-29
    90, 92, 94, 96, 98, 100, 102, 104, 106, 108,   -- 30-39
    110, 112, 114, 116, 118, 120, 122, 124, 126, 128, -- 40-49
    130                                              -- 50
}

function execute(ctx)
    local level = mud.UMIN(ctx.level, #dam_each)
    local base = dam_each[level] or dam_each[#dam_each]
    local dam = mud.number_range(base / 2, base * 2)

    if mud.saves_spell(level, ctx.victim) then
        dam = dam / 2
    end

    mud.damage(ctx.ch, ctx.victim, dam, ctx.sn, ELE.FIRE, true)
    return true
end
```

### Healing spell: Cure Light

Current C (~15 lines). Lua equivalent:
```lua
function execute(ctx)
    local heal = mud.dice(5, 8) + ctx.level
    heal = mud.UMIN(heal, 50)

    mud.heal(ctx.victim, heal)
    mud.send(ctx.victim, "@@aYou feel better!@@N\n")
    return true
end
```

### Buff spell: Armor

```lua
function execute(ctx)
    local victim = ctx.victim

    if victim:is_affected(ctx.sn) then
        mud.send(ctx.ch, "They are already armored.\n")
        return false
    end

    mud.apply_affect(victim, {
        type     = ctx.sn,
        duration = 24,
        location = APPLY.AC,
        modifier = -20,
        duration_type = DURATION.HOUR,
    })

    mud.act("$N is surrounded by a protective aura.", ctx.ch, nil, victim, "room")
    mud.send(victim, "@@aYou feel someone protecting you.@@N\n")
    return true
end
```

### DOT spell: Poison

```lua
function execute(ctx)
    local victim = ctx.victim

    if mud.saves_spell(ctx.level, victim) then
        mud.send(ctx.ch, "They resist your poison.\n")
        return false
    end

    mud.apply_affect(victim, {
        type     = ctx.sn,
        duration = ctx.level / 3,
        location = APPLY.DOT,
        modifier = ctx.level / 5,
        bitvector = AFF.POISON,
        duration_type = DURATION.ROUND,
    })

    mud.act("$N looks very ill.", ctx.ch, nil, victim, "room")
    mud.send(victim, "@@dYou feel very sick.@@N\n")
    return true
end
```

### Melee skill: Bash

Current C calls `war_attack()` directly. Lua equivalent:
```lua
function execute(ctx)
    local ch = ctx.ch
    local argument = ctx.argument

    if not ch:get_fighting() and argument == "" then
        mud.send(ch, "Bash whom?\n")
        return false
    end

    if not mud.can_use_skill(ch, ctx.sn) then
        return false
    end

    mud.subtract_energy(ch, ctx.sn)
    mud.wait_state(ch, ctx.beats)
    mud.raise_skill(ch, ctx.sn)
    mud.war_attack(ch, argument, ctx.sn)
    return true
end
```

### Complex spell: Animate (previously required CUSTOM C fallback)

This is one of the ~8 spells that could not be expressed as effect composition. With Lua, it needs no special handling:

```lua
function execute(ctx)
    local ch = ctx.ch
    local argument = ctx.argument

    -- Find the corpse in the room
    local corpse = mud.get_obj_room(ch:get_room(), argument)
    if not corpse or corpse:get_item_type() ~= ITEM.NPC_CORPSE then
        mud.send(ch, "You don't see that corpse here.\n")
        return false
    end

    -- Create the zombie mob
    local mob = mud.create_mobile(MOB_VNUM.ZOMBIE)
    if not mob then
        mud.send(ch, "The animation fails.\n")
        return false
    end

    -- Scale to caster
    mud.set_mob_level(mob, ch:get_level())
    mud.set_mob_max_hp(mob, ch:get_max_hp() / 2)
    mob:set_hp(mob:get_max_hp())

    -- Transfer items from corpse to mob and equip them
    -- Note: mud.interpret() is called here; see reentrancy note in Sandboxing.
    local items = mud.get_obj_contents(corpse)
    for _, item in ipairs(items) do
        mud.obj_from_obj(item)
        mud.obj_to_char(item, mob)
    end
    mud.interpret(mob, "wear all")

    -- Place in room and make follower
    mud.char_to_room(mob, ch:get_room())
    mud.add_follower(mob, ch)
    mud.extract_obj(corpse)

    mud.act("$n gestures at $p... it rises!", ch, corpse, nil, "room")
    mud.send(ch, "@@eYou animate the corpse!@@N\n")
    return true
end
```

### Complex spell: Chain Lightning (AOE with decay)

```lua
local dam_each = { --[[ level table as above ]] }

function execute(ctx)
    local ch = ctx.ch
    local victim = ctx.victim
    local level = ctx.level
    local base = dam_each[mud.UMIN(level, #dam_each)]
    local dam = mud.number_range(base / 2, base * 2)

    -- Primary target
    if mud.saves_spell(level, victim) then
        dam = dam / 2
    end
    mud.damage(ch, victim, dam, ctx.sn, ELE.LIGHTNING, true)

    -- Chain to others in room
    for _, vch in ipairs(mud.chars_in_room(ch:get_room())) do
        if vch ~= victim and vch ~= ch and not mud.is_safe(ch, vch) then
            dam = (4 * dam) / 5  -- 20% decay per target
            if mud.saves_spell(level, vch) then
                dam = dam / 2
            end
            mud.damage(ch, vch, dam, ctx.sn, ELE.LIGHTNING, true)
        end
    end

    return true
end
```

---

## Lua Engine Implementation

### Embedding: `src/lua/lua_engine.c`

A single `lua_State *` is created at boot and shared across all spell/skill invocations. Lua is single-threaded, which is fine -- the MUD game loop is also single-threaded.

```c
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static lua_State *L = NULL;

void lua_engine_init(void) {
    L = luaL_newstate();
    // Open only safe libraries -- no io, os, debug, loadfile, dofile
    luaL_requiref(L, "base",   luaopen_base,   1);  // print, type, pairs, etc.
    luaL_requiref(L, "table",  luaopen_table,   1);
    luaL_requiref(L, "string", luaopen_string,  1);
    luaL_requiref(L, "math",   luaopen_math,    1);

    // Remove dangerous globals from base library
    lua_pushnil(L); lua_setglobal(L, "dofile");
    lua_pushnil(L); lua_setglobal(L, "loadfile");
    lua_pushnil(L); lua_setglobal(L, "load");      // can compile arbitrary Lua at runtime

    // Replace Lua's built-in require() with a sandboxed version that
    // loads ONLY from the lua_libraries DB table -- never from the
    // filesystem. See "Controlled require()" section below.
    lua_pushcfunction(L, lua_custom_require);
    lua_setglobal(L, "require");

    // Register C API modules
    lua_register_mud_api(L);       // mud.damage(), mud.heal(), etc.
    lua_register_constants(L);     // ELE, AFF, APPLY, POS, CLASS, etc.
    lua_register_char_metatable(L); // char userdata with __index
    lua_register_obj_metatable(L);  // obj userdata with __index
    lua_register_room_metatable(L); // room userdata with __index
}

void lua_engine_shutdown(void) {
    if (L) lua_close(L);
    L = NULL;
}
```

### Script Loading and Caching

Scripts are loaded from PostgreSQL at boot. Each `skills.script_source` and `lua_libraries.source` is compiled to Lua bytecode and cached in a Lua registry table keyed by `sn` (for skills) or module name (for libraries), avoiding re-parsing on every cast.

Each script runs in its own isolated environment table (with `_G` as fallback via `__index`). This prevents scripts from polluting each other's globals while still seeing all game constants and the `mud` module.

```c
// Load and compile a script from its DB source, store its environment in registry
bool lua_load_skill_script(int sn, const char *source, const char *name) {
    // Compile the source string (not a file)
    if (luaL_loadbuffer(L, source, strlen(source), name) != LUA_OK) {
        log_string("Lua: compile error [%s]: %s", name, lua_tostring(L, -1));
        lua_pop(L, 1);
        return FALSE;
    }
    // Stack: [chunk]

    // Create isolated environment for this script
    lua_newtable(L);                        // [chunk, env]
    lua_newtable(L);                        // [chunk, env, mt]
    lua_getglobal(L, "_G");
    lua_setfield(L, -2, "__index");         // mt.__index = _G; [chunk, env, mt]
    lua_setmetatable(L, -2);               // env metatable set; [chunk, env]

    // Store env in registry BEFORE setupvalue consumes it from the stack
    luaL_getsubtable(L, LUA_REGISTRYINDEX, "skill_envs"); // [chunk, env, skill_envs]
    lua_pushvalue(L, -2);                  // [chunk, env, skill_envs, env]
    lua_rawseti(L, -2, sn);               // skill_envs[sn] = env; [chunk, env, skill_envs]
    lua_pop(L, 1);                         // [chunk, env]

    // Set env as the chunk's _ENV upvalue (consumes env from stack)
    lua_setupvalue(L, -2, 1);             // [chunk]

    // Execute the chunk to define execute() in env
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        log_string("Lua: runtime error [%s]: %s", name, lua_tostring(L, -1));
        lua_pop(L, 1);
        // Remove failed entry from registry
        luaL_getsubtable(L, LUA_REGISTRYINDEX, "skill_envs");
        lua_pushnil(L);
        lua_rawseti(L, -2, sn);
        lua_pop(L, 1);
        return FALSE;
    }
    // Stack: [] -- env is in registry, execute() is defined inside it
    return TRUE;
}

// Retrieve and push a named function from a script's environment
static bool lua_get_script_function(lua_State *L, int sn, const char *fname) {
    luaL_getsubtable(L, LUA_REGISTRYINDEX, "skill_envs"); // [skill_envs]
    lua_rawgeti(L, -1, sn);                                 // [skill_envs, env]
    lua_remove(L, -2);                                       // [env]
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return FALSE;
    }
    lua_getfield(L, -1, fname);                              // [env, fn]
    lua_remove(L, -2);                                       // [fn]
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return FALSE;
    }
    return TRUE;
}

// Load all shared libraries from lua_libraries table
void lua_load_libraries(void) {
    // SELECT name, source FROM lua_libraries ORDER BY name
    // For each row: luaL_loadbuffer + register as package in _LOADED
}

// Boot sequence: called from db_load_skill_table()
void lua_load_all_skill_scripts(void) {
    lua_load_libraries();  // shared modules first
    for (int sn = 0; sn < MAX_SKILL; sn++) {
        if (skill_table[sn].script_source[0] != '\0') {
            lua_load_skill_script(sn, skill_table[sn].script_source,
                                  skill_table[sn].name);
        }
    }
}
```

### Controlled `require()` for shared libraries

A custom `require()` is registered in the Lua VM that loads only from the `lua_libraries` cache -- never from the filesystem:

```c
// Custom require: loads from lua_libraries cache only
static int lua_custom_require(lua_State *L) {
    const char *modname = luaL_checkstring(L, 1);

    // Check if already loaded
    luaL_getsubtable(L, LUA_REGISTRYINDEX, "_LOADED");
    lua_getfield(L, -1, modname);
    if (!lua_isnil(L, -1)) return 1;  // already loaded, return cached
    lua_pop(L, 1);

    // Look up in lua_libraries cache (populated at boot)
    // ... compile and execute source, cache result in _LOADED
    return 1;
}
```

### Spell Dispatch

```c
bool lua_spell_execute(int sn, int level, CHAR_DATA *ch, void *vo, OBJ_DATA *obj) {
    if (skill_table[sn].script_source[0] == '\0')
        return FALSE;  // no script -- fall through to C

    if (!lua_get_script_function(L, sn, "execute")) {
        log_string("Lua: no execute() for spell [%s]", skill_table[sn].name);
        return FALSE;
    }

    // Build context table
    lua_newtable(L);
    lua_pushinteger(L, sn);                        lua_setfield(L, -2, "sn");
    lua_pushinteger(L, level);                     lua_setfield(L, -2, "level");
    lua_pushinteger(L, skill_table[sn].beats);     lua_setfield(L, -2, "beats");
    lua_push_char(L, ch);                          lua_setfield(L, -2, "ch");

    // Push victim/target based on skill_table[sn].target
    if (skill_table[sn].target == TAR_CHAR_OFFENSIVE ||
        skill_table[sn].target == TAR_CHAR_DEFENSIVE ||
        skill_table[sn].target == TAR_CHAR_SELF) {
        lua_push_char(L, (CHAR_DATA *)vo);
        lua_setfield(L, -2, "victim");
    } else if (skill_table[sn].target == TAR_OBJ_INV) {
        lua_push_obj(L, (OBJ_DATA *)vo);
        lua_setfield(L, -2, "obj_target");
    }

    if (obj) {
        lua_push_obj(L, obj);
        lua_setfield(L, -2, "cast_obj");
    }

    // Call with error handler
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        log_string("Lua spell error [%s]: %s",
                   skill_table[sn].name, lua_tostring(L, -1));
        lua_pop(L, 1);
        return FALSE;
    }

    bool result = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return result;
}
```

### Skill Dispatch

```c
void lua_skill_execute(int sn, CHAR_DATA *ch, char *argument) {
    if (skill_table[sn].script_source[0] == '\0') return;

    if (!lua_get_script_function(L, sn, "execute")) {
        log_string("Lua: no execute() for skill [%s]", skill_table[sn].name);
        return;
    }

    lua_newtable(L);
    lua_pushinteger(L, sn);                        lua_setfield(L, -2, "sn");
    lua_pushinteger(L, skill_table[sn].beats);     lua_setfield(L, -2, "beats");
    lua_push_char(L, ch);                          lua_setfield(L, -2, "ch");
    lua_pushstring(L, argument);                   lua_setfield(L, -2, "argument");

    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        log_string("Lua skill error [%s]: %s",
                   skill_table[sn].name, lua_tostring(L, -1));
        lua_pop(L, 1);
    } else {
        lua_pop(L, 1);
    }
}
```

### Hot Reload

A staff command `luareload <skill_name>` (or `luareload all`) re-queries the database and recompiles scripts at runtime without restarting the server:

```c
void do_luareload(CHAR_DATA *ch, char *argument) {
    if (argument[0] == '\0' || !str_cmp(argument, "all")) {
        // Re-query all skills + lua_libraries from DB, recompile all scripts
        db_reload_skill_scripts();
        lua_load_all_skill_scripts();
        send_to_char("All Lua scripts and metadata reloaded from database.\n", ch);
    } else {
        int sn = skill_lookup(argument);
        if (sn < 0) {
            send_to_char("No such skill.\n", ch);
            return;
        }
        // Re-query this skill's script_source from DB
        if (db_reload_skill_script(sn) && lua_load_skill_script(sn,
                skill_table[sn].script_source, skill_table[sn].name)) {
            send_to_char("Script reloaded from database.\n", ch);
        } else {
            send_to_char("Failed to reload script. Check logs.\n", ch);
        }
    }
}
```

The workflow for tuning a spell at runtime:
1. `UPDATE skills SET script_source = '...' WHERE name = 'fireball';` (via psql, tngdb admin, or a future in-game editor)
2. Type `luareload fireball` in-game.
3. The updated script is live immediately -- no compile, no reboot.

`luareload all` also reloads skill metadata (name, mana cost, beats, class levels, etc.) from the `skills` table and shared modules from `lua_libraries`, making it a full hot-reload of the entire skill/spell system.

### Sandboxing and Safety

The Lua VM is sandboxed to prevent scripts from:

1. **File I/O** -- `io`, `os`, `loadfile`, `dofile` are not opened. Additionally, `load` is explicitly removed from `_G` after `luaopen_base` runs -- `load` can compile arbitrary Lua from strings at runtime and would otherwise allow scripts to bypass sandboxing.
2. **Filesystem require** -- The built-in `require()` is replaced with a sandboxed version that loads only from the `lua_libraries` DB table -- never from the filesystem.
3. **Infinite loops** -- A Lua debug hook counts instructions and aborts scripts exceeding `MAX_LUA_INSTRUCTIONS` (defined in `src/lua/lua_engine.h`, default 100,000). This is far more than any spell needs and prevents a buggy script from hanging the game loop.
4. **Stack overflow** -- `lua_checkstack()` before deep operations.
5. **Memory exhaustion** -- A custom Lua allocator with a per-call byte ceiling.
6. **Direct memory access** -- Character/object/room data is accessed only through the metatable API, never through raw pointers.
7. **Reentrancy** -- A single `lua_State *` is shared across all invocations. Lua scripts must not trigger a second Lua dispatch while the VM is already executing a script (e.g. `mud.interpret()` executing a Lua-scripted command). A reentrancy guard detects this and logs an error rather than corrupting VM state:

```c
// Instruction limit hook
static void lua_instruction_hook(lua_State *L, lua_Debug *ar) {
    luaL_error(L, "Script exceeded instruction limit");
}

// Set before each script call
lua_sethook(L, lua_instruction_hook, LUA_MASKCOUNT, MAX_LUA_INSTRUCTIONS);
```

```c
// Reentrancy guard -- lua_spell_execute and lua_skill_execute both check this
static bool lua_executing = FALSE;

// Example guard in lua_spell_execute:
if (lua_executing) {
    log_string("Lua: reentrant call to lua_spell_execute [%s] -- skipped",
               skill_table[sn].name);
    return FALSE;
}
lua_executing = TRUE;
// ... dispatch ...
lua_executing = FALSE;
```

Scripts that legitimately need to trigger game commands (e.g. Animate using `mud.interpret(mob, "wear all")`) must ensure the invoked command does not itself dispatch a Lua script. For the initial implementation, `mud.interpret()` is restricted to a whitelist of non-Lua-dispatched commands (movement, `wear`, `remove`, `drop`, `get`). This constraint will be revisited if NPC AI scripting (Phase 6) requires recursive script dispatch.

### Error Handling

If a Lua script errors (syntax, runtime, instruction limit), the error is:
1. Logged to the server log with the script name and error message.
2. The spell/skill returns `FALSE` (spell fizzles, skill fails).
3. The game loop continues normally -- a broken script cannot crash the server.
4. If the caster is staff (level >= LEVEL_IMMORTAL), the error message is also sent to them in-game for debugging.

---

## NPC AI Scripting (Future Phase)

The same Lua engine and C API supports replacing compiled `spec_*.c` NPC special procedures with Lua scripts. This is **out of scope for the initial implementation** but is a key motivation for choosing Lua over a closed DSL.

### Current NPC AI architecture

Each NPC mob index has a `SPEC_FUN *spec_fun` -- a pointer to a C function with signature `bool spec_fn(CHAR_DATA *ch)`. The game loop calls this every combat round (for fighting NPCs) and on a random tick (for idle NPCs). There are 120+ spec functions in `src/ai/`, each compiled into the binary.

Additionally, `SPEECH_FUN *speech_fun` handles NPC responses to player speech, with signature `bool speech_fn(CHAR_DATA *mob, CHAR_DATA *player, const char *message)`.

### Future Lua NPC scripts

A future phase would add:

- NPC behavior scripts stored in a `npc_scripts` DB table with `on_tick(mob)`, `on_combat(mob)`, `on_speech(mob, player, message)` entry points.
- A `spec_lua` C function that dispatches to the appropriate Lua script based on the mob's `spec_script` field.
- The same `mud.*` and `char:*` APIs already built for spells/skills -- no new API layer needed.
- `SPEECH_FUN` handlers could also dispatch to Lua, coexisting with the existing LLM speech dispatch.

This is mentioned here to confirm that the Lua API surface designed for spells/skills is broad enough to serve NPC AI without a second scripting layer.

---

## Phasing

| Phase | What changes | Binary change? | Description |
|---|---|---|---|
| **1: Lua engine** | New `src/lua/` directory; Lua 5.4 linked into build | Yes | Embed Lua 5.4, register C API, sandboxing, error handling. No spells/skills moved yet. |
| **2: Metadata + scripts to DB** | `skills` and `lua_libraries` tables in PostgreSQL; boot loads from DB | Yes | `skill_table[]` populated from DB instead of compiled arrays. `script_source` column holds Lua source. Deletes `spell_table_data.c` + `skill_table_data.c`. |
| **3: All spell scripts** | All 246 `spell_*.c` migrated to Lua in DB | Yes | Migration tool translates all spell C functions to Lua. All spell `script_source` populated. All `spell_*.c` files deleted after test validation. |
| **4: All skill scripts** | All 109 `do_*.c` migrated to Lua in DB | Yes | Migration tool translates all skill C functions to Lua. All `do_*.c` files deleted after test validation. |
| **5: tngdb API** | `/skills` endpoints in tngdb | No | Expose skill metadata and script source via REST API for web frontend. |
| **6: NPC AI** (future) | NPC scripts in DB | Yes | Migrate `spec_*.c` to Lua. Out of scope for this proposal. |

### Phase details

**Phase 1** is the foundation -- it can be built and tested independently with a few test scripts before any real spells are migrated. It introduces the build dependency on Lua 5.4 (`liblua5.4-dev`).

**Phase 2** creates the `skills` and `lua_libraries` tables. The migration script parses the compiled C table data and populates the DB. Shared Lua utility modules (common damage table lookups, standard save-or-halve patterns) are created in `lua_libraries`.

**Phase 3** migrates all 246 spell C functions to Lua using automated tooling. The migration tool translates C source to Lua on a best-effort basis; any script it cannot translate mechanically is flagged for manual authoring. Unit tests are run against the complete Lua set before the `spell_*.c` files are deleted. Behavioral equivalence for edge cases not covered by existing tests should be verified through live testing on a staging server before the C originals are removed.

**Phase 4** follows the same pattern for all 109 skill C functions -- migration tool, manual review of flagged scripts, unit test validation, then bulk deletion.

**Phase 5** is unchanged from the original proposal.

**Phase 6** is future work, listed for architectural awareness only.

---

## Affected Files

### New files

| File | Description |
|---|---|
| `src/lua/lua_engine.c` | Lua VM lifecycle, script loading from DB, caching, hot reload |
| `src/lua/lua_engine.h` | Public declarations for lua_engine; defines `MAX_LUA_INSTRUCTIONS` |
| `src/lua/lua_api.c` | `mud.*` C API functions registered into Lua |
| `src/lua/lua_api.h` | Public declarations for lua_api |
| `src/lua/lua_char.c` | `char` userdata metatables (character property access) |
| `src/lua/lua_obj.c` | `obj` userdata metatables (object property access) |
| `src/lua/lua_room.c` | `room` userdata metatables (room property access) |
| `src/lua/lua_constants.c` | Constant registration (ELE, AFF, APPLY, POS, CLASS, etc.) |
| `src/db/db_skills.c` | DB boot loader for `skill_table[]` and Lua scripts from PostgreSQL |
| `src/db/db_skills.h` | Declarations for db_skills |
| `tools/migrate_skills_to_db.py` | Migration: parse C tables, populate DB metadata |
| `tools/migrate_spells_to_lua.py` | Migration: translate `spell_*.c` to Lua, insert into `skills.script_source` |
| `tools/migrate_skills_to_lua.py` | Migration: translate `do_*.c` to Lua, insert into `skills.script_source` |
| `tools/export_scripts.py` | Export all Lua scripts from DB to flat files for version control/review |

### Modified files

| File | Change |
|---|---|
| `area/schema.sql` | Add `skills` and `lua_libraries` tables |
| `src/headers/ack.h` | Add `script_source` field to `SKILL_TYPE`; add `serial` field to `CHAR_DATA`/`OBJ_DATA`; add Lua engine declarations |
| `src/db.c` | Call `lua_engine_init()` and `db_load_skill_table()` in `boot_db()` |
| `src/magic.c` | In `do_cast()` / `obj_cast_spell()`: dispatch to `lua_spell_execute()` when `script_source` is set |
| `src/interp.c` | For Lua-scripted skills: dispatch to `lua_skill_execute()` |
| `src/comm.c` | Call `lua_engine_shutdown()` on server shutdown |
| `src/Makefile` | Add `src/lua/` objects, link `-llua5.4`, add pkg-config for Lua |
| `fixtures/test_data.sql` | Add skill table data and Lua scripts for integration tests |

### Deleted files (after migration)

| Files | Count | When |
|---|---|---|
| `src/spells/spell_table_data.c` | 1 | Phase 2 |
| `src/skills/skill_table_data.c` | 1 | Phase 2 |
| `src/spells/spell_*.c` | ~246 | Phase 3 (after Lua equivalents validated) |
| `src/skills/do_*.c` | ~109 | Phase 4 (after Lua equivalents validated) |

---

## Trade-offs and Risks

| Risk | Mitigation |
|---|---|
| **New build dependency (Lua 5.4)** | Lua is a single `.a` / `.so` with zero transitive dependencies. `liblua5.4-dev` is available in all major distros. Added to `setup.sh` alongside existing deps. |
| **SN stability** | Unchanged from original proposal -- `sn` is PK, never reassigned. |
| **Lua performance vs direct C** | Lua function call overhead is ~1 microsecond. Spell logic is dominated by the C API calls (damage calc, affect application), not by the Lua wrapper. The instruction-count hook adds overhead to every Lua instruction; profiling needed but expected to be negligible for spell-sized scripts. |
| **Lua VM memory** | A single `lua_State` with ~400 cached script environments uses ~2-5 MB. Trivial compared to area data. Scripts loaded from DB are compiled to bytecode once at boot, not re-parsed per cast. |
| **Script errors in production** | Sandboxed execution with `lua_pcall` -- errors are caught, logged, and the spell fizzles. Server continues. Staff see errors in-game. |
| **Migration fidelity** | Migration tools translate C source to Lua on a best-effort basis. Scripts the tool cannot translate mechanically are flagged for manual authoring. Unit tests validate migrated scripts before C originals are deleted, but behavioral equivalence for edge cases not covered by tests should be verified via live staging before deletion. |
| **Scripts in DB vs filesystem** | DB storage means scripts are versioned alongside metadata, backed up with the database, and editable via tngdb admin UI. The trade-off is that editing requires a DB client or admin tool rather than a text editor + git. `tools/export_scripts.py` exports all scripts to files for version control and review. |
| **Instruction limit tuning** | Configured via `MAX_LUA_INSTRUCTIONS` in `src/lua/lua_engine.h`, defaulting to 100,000. Adjust based on profiling if needed. |
| **Stale char/obj userdata** | `CHAR_DATA` and `OBJ_DATA` gain a `uint32_t serial` field, initialized from a global monotonically-increasing counter at allocation and updated at `extract_char()` / `extract_obj()`. Userdata stores `{ptr, serial}`. Before each C API call, the wrapper checks `ptr->serial == stored_serial`; a mismatch (indicating the slot was extracted and potentially reused) causes the API call to return `nil` or raise a Lua error rather than dereferencing a dangling pointer. |
| **Reentrancy via mud.interpret()** | `mud.interpret()` is initially restricted to a whitelist of non-Lua-dispatched commands. The reentrancy guard catches any violation and logs an error rather than corrupting the Lua VM. This is revisited in Phase 6 if NPC AI scripting requires recursive dispatch. |
| **DB unavailable at boot** | `db_load_skill_table()` calls `exit()` on failure -- same as all other DB boot connections. |

### Intentional Non-Changes

- `MAX_SKILL` (999) ceiling unchanged.
- `learned[]`, `cooldown[]`, `can_use_skill()`, `mana_cost()`, `raise_skill()` -- all unchanged in C. Lua scripts call into these existing C functions via the API.
- `skill_lookup()` still searches `skill_table[]` (now DB-loaded) -- no change to call sites.
- `war_attack()`, `combo()`, `calculate_damage()`, `sp_damage()` -- remain in C. Lua scripts call them, they don't reimplement them.
- The spell/skill dispatch in `magic.c` and `interp.c` is minimally changed -- a single `if (script_source[0]) lua_*_execute(...)` check before the existing C path.
- NPC `skills`/`power_skills` bitfields -- out of scope.
- Player save format -- unchanged. `learned[]` and `cooldown[]` are indexed by `sn` which is stable.

---

## Comparison with Original Effect-Composition Approach

| Aspect | Original (JSONB effects) | Revised (Lua scripts) |
|---|---|---|
| **Spell logic storage** | JSONB blobs in `skill_effects` table rows | Lua source in `skills.script_source` column (PostgreSQL) |
| **Expressiveness** | Fixed taxonomy of ~15 effect types | Full programming language |
| **Complex spells** | Require `CUSTOM` C fallback (~8+ spells) | All spells expressible in Lua, no fallback needed |
| **Formula language** | Custom DSL (`"5d8+level"`) parsed in C | Native Lua arithmetic (`dice(5,8) + level`) |
| **Conditional logic** | Not supported (or JSONB `"conditions"` arrays) | Native `if/elseif/else` |
| **Iteration** | Not supported (AOE hardcoded as effect type) | Native `for` loops |
| **New DB tables** | `skills` + `skill_effects` | `skills` + `lua_libraries` |
| **Hot reload** | DB UPDATE + server reload command | DB UPDATE + `luareload` command |
| **NPC AI path** | Would need a separate system | Same Lua engine, same API |
| **Testing** | Assert JSONB output matches expected | Run Lua scripts in test harness with mock API |
| **Tooling for authors** | Edit JSONB in DB or via tngdb admin UI | Edit Lua in DB via tngdb admin UI or psql; export to files for version control |

---

## Resolved Design Decisions

1. **Lua version**: **Lua 5.4.** Stable, native integer support (important for MUD integer math), widely packaged, no external dependencies.

2. **Script storage**: **PostgreSQL, not flat files.** Lua source is stored in `skills.script_source` and `lua_libraries.source`. Scripts are loaded from DB at boot and compiled to bytecode in the Lua VM. No flat `.lua` files on disk. `tools/export_scripts.py` can export scripts to files for version control if needed.

3. **Migration tooling**: **Best-effort automated.** Migration tools translate C source to Lua programmatically. Any script the tool cannot translate mechanically is flagged for manual authoring. The goal is to minimize manual effort, not guarantee zero intervention.

4. **Validation strategy**: **All at once per phase.** Phase 3 migrates all 246 spells in one batch; Phase 4 migrates all 109 skills in one batch. Unit tests are run against the complete Lua set to validate equivalence before deleting the C files. Live staging verification is required for edge cases not covered by unit tests.

5. **Shared Lua libraries**: **Yes.** Common patterns (damage tables, save-or-halve, standard buff application) are extracted into shared modules in the `lua_libraries` table. A controlled `require()` loads only from this table -- never from the filesystem.

6. **tngdb API**: **Public read-only**, consistent with existing endpoints.

7. **Hot reload scope**: **Full reload.** `luareload all` reloads both skill metadata and Lua scripts from the database. `luareload <name>` reloads a single skill's script and metadata.
