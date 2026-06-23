# Melee Combat Abilities Configuration

This document explains how to set up **melee combat abilities** (disciplines and kick/bash-style abilities) for melee classes. In bobblebot, combat abilities are configured using the **debuff** system: you add disciplines or abilities as debuff entries with **gem** `'disc'` or `'ability'` and use **bands** to choose which mobs they hit.

## Overview

- **Melee combat abilities = debuffs.** There is no separate "melee abilities" section. You add your discipline(s) or ability/ability slot (e.g. kick, bash, backstab) under **`config.debuff.spells`** with **gem** `'disc'` (disciplines) or `'ability'` (e.g. kick, bash), and set **bands** (e.g. **matar** for the MA's target).
- **Both switches required:** **`settings.domelee`** enables stick/attack and engage (see [Tanking configuration](tanking-configuration.md)). **`settings.dodebuff`** enables the debuff loop, which is what actually fires disciplines and abilities. For a melee to auto-attack and use discs/abilities, both must be on.
- For all debuff options (delay, mintar/maxtar in bands, precondition, etc.), see [Debuffing configuration](debuffing-configuration.md).
- See [Spell targeting and bands](spell-targeting-and-bands.md) for how matar and notmatar interact and evaluation order.

---

## How to configure melee combat abilities

1. **Enable melee and debuffing:** In config set **`settings.domelee`** and **`settings.dodebuff`** to `true`, or run `/cz domelee on` and `/cz dodebuff on`.

2. **Add a debuff entry** under **`config.debuff.spells`**:
   - **gem** — `'disc'` for disciplines (e.g. defensive, offensive discs) or `'ability'` for combat abilities (e.g. kick, bash, backstab).
   - **spell** — Exact discipline or ability name as MQ expects (e.g. the name shown in your discipline list or ability window).
   - **enabled** — Optional; default is `true`. When `false`, the spell is not used.
- **bands** — For abilities on the MA's target use **matar**. Optionally **notmatar** (adds) or **named**. Use **min**/ **max** to restrict by mob HP %.
   - **delay** — Optional. Delay (ms) before the same ability can be used again; useful for cooldown control.
   - **mintar** / **maxtar** — Optional; set in **bands**. Camp mob-count gate. See [Debuffing configuration](debuffing-configuration.md).

3. **Optional:** **precondition** (boolean or Lua script to allow/skip the cast), **alias** (for `/cz cast <alias>`), **minmana** (not usually needed for discs/abilities).

**Example: one discipline on tank target**

```lua
debuff = {
  spells = {
    {
      gem = 'disc',
      spell = 'Name of Your Discipline',
      bands = {
        { validtargets = { 'matar' }, min = 5, max = 100 }
      },
      enabled = true,
      delay = 0
    }
  }
}
```

**Example: discipline plus kick (ability)**

Add a second entry for an ability such as kick; use **gem** `'ability'` and the ability name as **spell**:

```lua
{
  gem = 'ability',
  spell = 'Kick',
  bands = {
    { validtargets = { 'matar' }, min = 1, max = 100 }
  },
  enabled = true,
  delay = 0
}
```

---

## Runtime control

- **Toggle melee:** `/cz domelee on` or `/cz domelee off`.
- **Toggle debuffing (combat abilities):** `/cz dodebuff on` or `/cz dodebuff off`.
- **Cast by alias:** `/cz cast <alias> [target]` — cast a debuff by alias. `/cz cast <alias> on` or `off` to enable or disable that spell (**enabled**).
- **Add a spell slot:** `/cz addspell debuff <position>`.

---

## See also

- [Debuffing configuration](debuffing-configuration.md) — Full debuff options (recast, delay, precondition, etc.).
- [Tanking configuration](tanking-configuration.md) — Melee/tank settings (stick, assist, camp).
- [Spell targeting and bands](spell-targeting-and-bands.md) — Targeting logic and band tags (matar, notmatar, named).
