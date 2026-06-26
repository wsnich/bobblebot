# Debuffing Configuration

This document explains how to configure the bot’s **debuffing** behavior: which detrimental spells are cast on which mobs (tank target, adds, named) and options such as charm, recast, and delay. **Nuking**, **mezzing**, and **melee combat abilities** use this same debuff system; see [Nuking configuration](nuking-configuration.md), [Mezzing configuration](mezzing-configuration.md), and [Melee combat abilities](melee-combat-abilities.md) for those use cases.

## Overview

- **Master switch:** Debuffing runs only when **`settings.dodebuff`** is `true`. Default is `false`.
- **Mob list:** The bot builds a list of valid mobs (within **acleash** and **zradius** of camp, filtered by **TargetFilter**). Debuffs are only cast on mobs in this list. **Soulbinders** and **translocators** are never debuffed. Debuffs are skipped in **no-combat zones** and near the **primary bind point** (bind stealth). See [Safety and stealth](safety-and-stealth.md).
- **Evaluation order:** The bot evaluates **phases** in order: **charm** (if the zone has a **Charm list** and a charm spell is configured) → **burn** (only while a burn window is active — see [Burn window](#burn-window)) → **notmatar** (other mobs / adds) → **matar** (MA/tank’s current target) → **named** (named mobs that are the tank target). For each phase it considers each mob target and checks **all** debuff spells that have that phase in their bands before moving on. For a detailed explanation of spell targeting logic and how band tags interact, see [Spell targeting and bands](spell-targeting-and-bands.md).
- **Melee combat abilities** (disciplines, kick/bash-style abilities) use this same debuff system with **gem** `'disc'` or `'ability'`; see [Melee combat abilities](melee-combat-abilities.md).

---

## Config file reference

### Settings

| Option | Default | Purpose |
|--------|--------|---------|
| **dodebuff** | `false` | Boolean. Enables or disables the debuff loop. |

### Debuff section

All debuff options are under **`config.debuff.spells`**. Each spell entry can have:

| Field | Purpose |
|-------|---------|
| **gem** | Spell gem number (1–12), or `'item'`, `'alt'`, `'disc'`, `'ability'`, `'script'`. |
| **spell** | Spell name (or item name if gem is `'item'`). |
| **alias** | Optional. Short name for `/cz cast <alias>`. Pipe-separated for multiple. |
| **announce** | Optional. If true, announce when casting. |
| **minmana** | Minimum mana (absolute) to cast. |
| **enabled** | Optional. When `true` or missing, the spell is used. When `false`, the spell is not used. Default is `true`. |
| **bands** | Which mobs and at what HP %. See [Debuff bands](#debuff-bands) below. |
| **recast** | Optional. For most debuffs: after this many resists on the **same** spawn, the bot disables this spell for that spawn for a duration. 0 = no limit. For **concussion** (aggro-reduce, SPA 92) debuffs, recast means “cast every N other debuffs” on the tank target (e.g. recast 2 → two nukes/debuffs, then concussion, repeat); autodetected when the spell has SPA 92 and recast &gt; 0. |
| **delay** | Optional. Delay (ms) before the spell can be used again after cast (per-index/spell). |
| **precondition** | Optional. When missing or not set, defaults to `true` (cast is allowed). When **defined**: **boolean** — `true` = allow, `false` = skip; **string** — Lua script with `mq` and `EvalID` in scope; return truthy to allow the cast. |
| **dontStack** | Optional. List of debuff **categories** (from MQ Target TLO). If the target already has any of these categories (e.g. from another character), the bot will not cast this spell on that target, and will interrupt the cast if that category appears on the target while casting. For **bard conditional matar** debuffs, triggers twist-once instead of combat-twist inclusion. Allowed values (see code block below). Example: for a bard snare, set `dontStack = { 'Snared' }` so the bot does not overwrite a ranger's or druid's snare. |
| **stopWhen** | Optional. List of debuff **categories**. Skip cast when the target already has any listed category — use when the spell's job is done (not "don't overwrite"). For **bard conditional matar**, uses twist-once instead of combat twist. Example: `stopWhen = { 'Slowed' }` on **Occlusion of Sound** (resist debuff) so the bard stops singing it once any slow is on the MA target. **Slowed** is only valid in **stopWhen**, not **dontStack** (casters may still overwrite weaker slows). |

Allowed **dontStack** values:

```
Charmed, Crippled, Feared, Maloed, Mezzed, Rooted, Snared, Tashed
```

Allowed **stopWhen** values:

```
Charmed, Crippled, Feared, Maloed, Mezzed, Rooted, Slowed, Snared, Tashed
```

### Debuff bands

Bands define **which mobs** and **at what HP %** the debuff is allowed. Debuff uses **targetphase** only (no validtargets; target is always mobs). Each band has:

- **targetphase:** One or more of: **charm**, **burn**, **matar**, **notmatar**, **named**.
  - **charm** — Mobs on the zone **Charm list** (when a charm spell is configured).
  - **burn** — Only evaluated while a burn window is active (**`/cz burn [seconds]`** or Status **Burn**). Combine with **matar**, **notmatar**, or **named** to pick which mobs; burn-only (no other phase) defaults to the MA target.
  - **matar** — The Main Assist’s current target. If a debuff band has `onlyMT=true`, then `matar` casts on the Main Tank’s target instead (only when this bot is the Main Tank).
  - **notmatar** — Any other mob in the list (adds).
  - **named** — Named mobs. With `matar`, the chosen `matar` target is required to be named (MA by default, MT when `onlyMT=true`).
- **Migration note:** Legacy `tanktar`/`notanktar` tokens are accepted as aliases for `matar`/`notmatar` so existing configs keep working. New configurations should use the canonical `matar`/`notmatar` names.
- **min** / **max:** Mob HP % range (0–100). The mob’s HP must be in this range to be considered.
- **aggroMin** / **aggroMax:** Optional. Your **Me.PctAggro** range (0–100). Default 0 / 100 (no gate). Only applies at level 20+; below level 20 the gate is ignored. Bands are merged across the spell like HP %.

- **mintar** / **maxtar:** Optional. Camp mob-count gate (total mobs in camp). Omit the field or set to **0** for no limit. **mintar = X, maxtar = nil** — only consider this spell when camp mob count ≥ X (X &gt; 0). **mintar = nil, maxtar = X** — effective minimum is 1; only consider when 1 ≤ mob count ≤ X (X &gt; 0). **mintar = X, maxtar = Y** — only consider when X ≤ mob count ≤ Y. For **targeted AE** spells (auto-detected when spell TargetType is "Targeted AE" and AERange > 0), **mintar** is also the minimum number of mobs **within the spell's AERange of the candidate target** (so the spell is not cast on a lone add with no other mobs in AE range). If a spell has only **notmatar** in its bands and neither **mintar** nor **maxtar** is set in any band, the bot defaults **mintar** to 2 so the spell is only considered when there is at least one add (optimization).

**Example: nuke on tank target and slow on adds**

```lua
debuff = {
  spells = {
    {
      gem = 1,
      spell = 'Chaos Flame',
      alias = 'nuke',
      minmana = 0,
      bands = {
        { targetphase = { 'matar' }, min = 5, max = 100, mintar = 10 }
      },
      recast = 0,
      delay = 0,
      precondition = true
    },
    {
      gem = 2,
      spell = 'Turgur\'s Insects',
      alias = 'slow',
      minmana = 0,
      bands = {
        { targetphase = { 'notmatar' }, min = 20, max = 100, mintar = 5 }
      },
      recast = 2,
      delay = 0,
      precondition = true
    }
  }
}
```

---

## Charm (special case)

**Charm spells are auto-detected** (spell has the Charm effect, SPA 22). Add your charm spell as a debuff entry. The list of mob names the bot is allowed to charm is a **per-zone list** in the common config: use the **Mob Lists** tab in the UI (Charm list) or **`/cz charm <name>`** / **`/cz charm remove <name>`** to add or remove mobs. When charm breaks, the bot can request a recast on that spawn. Before casting charm, the bot issues **pet leave** so your current pet is released. See also [Pets configuration](pets-configuration.md) for charm in context.

---

## Casting retries

For debuff spells, `lib/casting.lua` retries once (`maxTries = 2`) on retryable failures (for example resist/fizzle/interrupt) before returning a final result. The bot still sees one logical completion: **recast** (disable after N resists per spawn) and **afterCast** logic run once per cast using the final cast result.

---

## Runtime control

- **Toggle debuffing:** `/cz dodebuff on` or `/cz dodebuff off` (or `/cz dodebuff` to toggle).
- **Burn window:** `/cz burn [seconds]` opens a timed window; `/cz burn off` closes it. Debuffs with a **burn** band phase cast only during the window. Use for burn disciplines, epic clicks, or high-cost nukes you do not want in steady state.
- **Cast by alias:** `/cz cast <alias> [target]` — cast a debuff by alias. Use `/cz cast <alias> on` or `off` to enable or disable that spell (**enabled**).
- **Add a spell slot:** `/cz addspell debuff <position>` — insert a new debuff entry at the given position.

---

## Behavior summary

- **Immune check:** The bot can skip mobs marked immune to the spell (per zone/target in immune data).
- **Before cast (matar):** When casting on the MA target, the bot may set **engageTargetId** to that mob (so melee/pet follow) and send pet attack if **petassist** is on.
- **Recast:** After **recast** resists on the same spawn, the spell is disabled for that spawn for a duration.
- **Level:** For some spell types (e.g. Enthrall/mez), the spell’s **MaxLevel** is checked against the mob’s level; over-level mobs are skipped.
- **dontStack:** If a debuff entry has **dontStack** set, the bot will not cast it when the current target already has that category (e.g. already Snared), and will interrupt the cast if that category appears on the target while casting (e.g. another toon's snare lands). The bot records the other spell's duration so it does not re-attempt the same debuff on that mob every tick. **Bard conditional matar** debuffs use twist-once when needed instead of joining the combat twist.
- **stopWhen:** Skip when the target already has the listed category (e.g. **Slowed** after a resist-setup debuff like Occlusion of Sound has done its job). Applies to casts and marks **bard matar** debuffs as conditional (twist-once). Unconditional matar debuffs (e.g. `max` equal to **assistpct**) stay in the combat twist.

### Burn window

A burn window is a **runtime timer** (not saved in config). While active, the debuff loop runs the **burn** phase before **notmatar**. Spells with **burn** in their band **targetphase** are excluded from normal **matar** / **notmatar** / **named** passes so they do not fire outside the window.

**Example: epic/click only during burn on MA target**

```lua
{
  gem = 'item',
  spell = 'My Epic Click',
  bands = {
    { targetphase = { 'burn', 'matar' }, min = 5, max = 100 }
  }
}
```

Open the window with **`/cz burn 30`** (30 seconds) or the Status tab **Burn** button. **`/cz burn off`** ends it early.

---

## See also

- [Nuking configuration](nuking-configuration.md) — Configure nukes as debuffs (typically **matar**, optionally **notmatar**). Multiple nukes rotate; flavor (fire/ice/magic, etc.) is auto-detected and can be filtered at runtime via Status tab or `/cz togglenuke`.
- [Mezzing configuration](mezzing-configuration.md) — Configure mez as debuffs (typically **notmatar**; Charm list for charm mez).
- [Melee combat abilities](melee-combat-abilities.md) — Configure disciplines and /doability-style abilities as debuffs (typically **matar**).
