# Nuking Configuration

This document explains how to set up **nuking** (direct-damage spells on the tank’s or MA’s target, or on adds). In bobblebot, nuking is configured using the **debuff** system: you add nuke spells as debuff entries and use **bands** to choose which mobs they hit.

## Overview

- **Nuking = debuffs.** There is no separate “nuke” section. You add your nuke spell(s) under **`config.debuff.spells`** and set **bands** to **matar** (MA target), and optionally **notmatar** (adds) or **named** (named only).
- **Master switch:** Turn on debuffing with **`settings.dodebuff`** (or `/cz dodebuff on`).
- **Nuke rotation:** If you configure multiple nuke spells (e.g. Shock of Ice and Shock of Fire), the bot **rotates** between them—one cast of each in sequence—instead of only ever casting the first. Nukes are auto-detected (spells with no duration).
- **Nuke flavor (resist type):** Each nuke’s **flavor** (fire, ice, magic, poison, disease, etc.) is **auto-detected** from the spell’s resist type. You can disable specific flavors at runtime (e.g. turn off fire nukes in Plane of Fire) via the Status tab checkboxes or **`/cz togglenuke <flavor> [on|off]`**. Settings are stored per zone in **cz_common.lua** in the per-zone block **zones**[*zone*] (**nukeFlavors**, **nukeFlavorsAutoDisabled**).
- **Recast and auto-disable:** The existing **recast** option (resist count per spawn) applies to nukes. If the same flavor is disabled due to resists on **3 mobs in a row**, that flavor is **globally auto-disabled** until you re-enable it (checkbox or `/cz togglenuke <flavor> on`).
- For all debuff options (recast, delay, charm, gem types, etc.), see [Debuffing configuration](debuffing-configuration.md).
- See [Spell targeting and bands](spell-targeting-and-bands.md) for how matar and notmatar interact and evaluation order.

---

## How to configure nuking

1. **Enable debuffing:** In config set **`settings.dodebuff`** to `true`, or run `/cz dodebuff on`.

2. **Add a debuff (nuke) spell entry** under **`config.debuff.spells`**:
   - **gem** — Spell gem number (1–12) or `'item'`, `'alt'`, `'disc'`.
   - **spell** — Exact spell name (e.g. `"Chaos Flame"`).
   - **enabled** — Optional; default is `true`. When `false`, the spell is not used.
   - **mintar** / **maxtar** — Optional; set in **bands**. Camp mob-count gate (only consider when mob count is in range). E.g. **mintar 2** = at least two mobs in camp. See [Debuffing configuration](debuffing-configuration.md).
   - **bands** — Debuff bands use **targetphase** (not validtargets). For nuking the main target use **matar** in targetphase. For multi-target or add nuking add **notmatar**. For named-only nukes add **named**. Use **min**/ **max** to restrict by mob HP % (e.g. nuke only when mob is 5–100% HP).

3. **Optional:** **recast** (resist count before disabling for that spawn), **delay** (ms before same spell can be used again), **alias** (for `/cz cast <alias>`), **minmana**.

**Example: single-target nuke on MA target**

```lua
debuff = {
  spells = {
    {
      gem = 1,
      spell = 'Chaos Flame',
      alias = 'nuke',
      minmana = 0,
      bands = {
        { targetphase = { 'matar' }, min = 5, max = 100 }
      },
      recast = 0,
      delay = 0
    }
  }
}
```

**Example: nuke tank target and adds**

Use **matar** and **notmatar** in the same band (or separate bands) so the nuke can fire on the MA target and on other mobs in the list:

```lua
bands = {
  { targetphase = { 'matar', 'notmatar' }, min = 10, max = 100 }
}
```

---

## Runtime control

- **Toggle debuffing (nuking):** `/cz dodebuff on` or `/cz dodebuff off`.
- **Nuke flavor filter:** `/cz togglenuke <flavor>` — toggle that flavor on or off (e.g. `/cz togglenuke ice`). Use `/cz togglenuke <flavor> off` or `on` to force off or on. Flavors: **fire**, **ice** (or **cold**), **magic**, **poison**, **disease**. Only flavors that appear in your configured nukes are valid. Settings are saved per zone in **cz_common.lua** in the per-zone block **zones**[*zone*] (nukeFlavors, nukeFlavorsAutoDisabled).
- **Status tab:** When you have at least one nuke in your debuff list, the Status tab shows a row of checkboxes for each nuke flavor (Fire, Ice, Magic, etc.). Uncheck a flavor to disable it (e.g. fire in a fire-resistant zone). Auto-disabled flavors (after 3 resists in a row) appear unchecked; you can re-enable them by checking the box or using `/cz togglenuke <flavor> on`.
- **Cast by alias:** `/cz cast <alias> [target]` — cast the nuke by alias. `/cz cast <alias> on` or `off` to enable or disable the spell (**enabled**).
- **Add a spell slot:** `/cz addspell debuff <position>`.

---

## See also

For full debuff options (recast, delay, charm, immune check, level checks, etc.), see [Debuffing configuration](debuffing-configuration.md).
