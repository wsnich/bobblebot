# Mezzing Configuration

This document explains how to set up **mezzing** (crowd control: mez spells on adds, and charm). In bobblebot, mezzing is configured using the **debuff** system: you add mez (and optionally charm) spells as debuff entries and use **bands** to choose which mobs they hit.

## Overview

- **Mezzing = debuffs.** There is no separate “mez” section. You add your mez spell(s) under **`config.debuff.spells`** and set **bands** to **notmatar** (adds) so the bot mezzes mobs other than the MA’s target. Optionally use **matar** or **named** for specific cases.
- **Charm** (mez that makes the mob your pet) uses the same debuff entries; charm spells are auto-detected. Add your charm spell as a debuff and manage allowed mob names in the **Charm list** for the current zone (Mob Lists tab or `/cz charm`). When charm breaks, the bot can recast. See [Debuffing configuration](debuffing-configuration.md).
- **Level:** The bot checks the spell’s **MaxLevel** against the mob’s level for Enthrall-type spells; mobs above that level are skipped.
- For all debuff options (recast, delay, immune check, etc.), see [Debuffing configuration](debuffing-configuration.md).

---

## How to configure mezzing

1. **Enable debuffing:** In config set **`settings.dodebuff`** to `true`, or run `/cz dodebuff on`.

2. **Add a debuff (mez) spell entry** under **`config.debuff.spells`**:
   - **gem** — Spell gem number (1–12) or `'item'`, `'alt'`, `'disc'`.
   - **spell** — Exact spell name (e.g. an Enthrall or mez spell).
   - **enabled** — Optional; default is `true`. When `false`, the spell is not used.
   - **mintar** / **maxtar** — Optional; set in **bands**. Camp mob-count gate (only consider when mob count is in range). E.g. **mintar 2** = mez when there are at least two mobs in camp (one add). When omitted, notmatar-only bands default **mintar** to 2. See [Debuffing configuration](debuffing-configuration.md).
- **bands** — For mezzing **adds**, use **notmatar** in **targetphase** (debuff uses **targetphase** only, not validtargets; use **targetphase** for matar, notmatar, named). Optionally add **named** to allow mezzing named mobs that are not the MA target. Use **min**/ **max** to restrict by mob HP % (e.g. mez only when mob is 20–100% HP so you don't mez nearly-dead adds). See [Spell targeting and bands](spell-targeting-and-bands.md) for targeting and band details.

3. **Optional:** **Targeted AE** spells (e.g. AE mez like Mezmerization) are **auto-detected**. For those spells the bot only casts on targets farther than the spell's AERange + 2, and **mintar** (in bands) is the minimum number of adds within AE range of the chosen target. See [Debuffing configuration](debuffing-configuration.md). **recast**, **delay**, **alias**, **minmana**, **precondition** (default true when missing; when set, boolean or Lua script to allow/skip the cast).

**Example: mez adds only**

You do not need to set **mintar** here; for notmatar-only bands it defaults to 2.

```lua
debuff = {
  spells = {
    {
      gem = 2,
      spell = 'Bellow of the Mastruq',
      alias = 'mez',
      minmana = 0,
      bands = {
        { targetphase = { 'notmatar' }, min = 20, max = 100 }
      },
      recast = 2,
      delay = 0
    }
  }
}
```

**Example: charm mez**

Add your charm spell as a debuff entry (charm spells are auto-detected). Manage allowed mob names in the **Charm list** for the current zone (Mob Lists tab or `/cz charm`). The bot will **pet leave** before casting and can request a recast when charm breaks. Set bands as needed (e.g. notmatar, min 30, max 100).

---

## Level limits

For Enthrall-type (mez) spells, the bot uses the spell’s **MaxLevel** and the mob’s level. If the mob is above **MaxLevel**, the spell is not cast on that mob. This is handled automatically; you do not set level in the config.

---

## Runtime control

- **Toggle debuffing (mezzing):** `/cz dodebuff on` or `/cz dodebuff off`.
- **Cast by alias:** `/cz cast <alias> [target]` — cast the mez by alias. `/cz cast <alias> on` or `off` to enable or disable the spell (**enabled**).
- **Add a spell slot:** `/cz addspell debuff <position>`.

---

## See also

For full debuff options (recast, delay, charm, immune check, before-cast behavior, etc.), see [Debuffing configuration](debuffing-configuration.md). For charm as a pet, see [Pets configuration](pets-configuration.md).
