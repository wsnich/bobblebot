# Healing Configuration

This document explains how to configure the bot’s **healing** behavior: which spells are used, who gets healed and at what HP, resurrection, and related options. It is intended for operators who set up the config file and use runtime commands.

## Overview

- **Master switch:** Healing runs only when **`settings.doheal`** is `true`. Default is `false`.
- **Heal target:** The heal loop runs **two passes** when no cast is in progress. **Pass 1 (HP):** evaluates **phases** in order (see [Heal bands](#heal-bands)): corpse (rez) → self → groupheal → tank → groupmember → pc → mypet → pet → xtgt, using only spells where **healResource** is `'hp'` (the default, including corpse rez). For each phase it gets the list of targets for that phase, then for **each target** checks all matching heal spells (in config order). The first spell that the target needs (HP in band, in range) is cast. **Pass 2 (Mana):** runs the same phase order with only **healResource** `'mana'` spells (e.g. cannibalize), and only when pass 1 found nothing to cast. The **Main Tank** (from TankName) is the resolved tank when the **tank** phase is checked.
- **Where to configure:** Set **`settings.doheal`** in the `settings` section and all heal options under the **`heal`** section. See [Config file reference](#config-file-reference) below.

---

## Config file reference

### Settings

| Option | Default | Purpose |
|--------|--------|---------|
| **doheal** | `false` | Boolean. Enables or disables the heal loop. When `true`, the `heal` section is used. |

### Heal section (top-level)

All heal options live under **`config.heal`**. Spell entries are in **`heal.spells`**.

| Option | Default | Purpose |
|--------|--------|---------|
| **rezoffset** | 0 | When multiple corpses are in range, skip this many before picking a rez target (e.g. rez the 2nd corpse when rezoffset is 1). |
| **interruptlevel** | 0.80 | Used when deciding whether to interrupt a cast (e.g. for a higher-priority heal). Target HP threshold. |
| **xttargets** | 0 | Comma- or digit-separated extended target slot numbers (e.g. `1,2,3` or `123`) that are valid for heals. When set, spells with band **xtgt** can heal those XTarget slots. |

### Group AE heals (MQ TargetType Group v1 / Group v2)

For spells whose MQ **TargetType** is **Group v1** or **Group v2**, the bot does **not** force a friendly target: casting is started without retargeting and skips `/tar` to the caster, so you may keep a **mob** targeted or **no target** and the spell still applies to the group. **`interruptlevel`** does **not** apply to these spells (no HP-threshold interrupt on the current target). While the cast bar is active, the bot re-evaluates the same **groupheal** logic as pre-cast (`tarcnt`, HP band, AE range) and **interrupts** if the group would no longer qualify.

### Heal spell entries

Each entry in **`heal.spells`** can have:

| Field | Purpose |
|-------|---------|
| **gem** | Spell gem number (1–12), or `'item'`, `'alt'`, `'disc'`, `'script'` for non-gem casts. |
| **spell** | Spell name (or item name if gem is `'item'`). |
| **alias** | Optional. Short name for `/cz cast <alias>`. Pipe-separated for multiple aliases. |
| **announce** | Optional. If true, announce when casting (e.g. to group). |
| **minmana** | Minimum mana (absolute) to cast. |
| **minmanapct** / **maxmanapct** | Your mana % must be within this range to use this spell (default 0–100). |
| **enabled** | Optional. When `true` or missing, the spell is used. When `false`, the spell is not used. Default is `true`. |
| **tarcnt** | Optional. Only used for **group/AE heals**: minimum number of group members in the HP band (and in range) required to trigger the spell. When omitted, group heals fire when at least 1 member is in band. Not used for single-target heals. |
| **bands** | Who and at what HP % this spell applies. Each band has **targetphase** (phase stages) and **validtargets** (within-phase types). See [Heal bands](#heal-bands) below. |
| **healResource** | Optional. `'hp'` (default) or `'mana'`. When `'mana'`, the spell is treated as a mana heal (e.g. Cleric Canni); min/max in bands apply to **mana %** of the target, not HP. When `'mana'`, self phase may be skipped for that spell under certain logic. |
| **inCombat** | Optional. When `true` and the spell has **corpse** in a band, rez is allowed when mobs are in camp. Default is `false`. |
| **precondition** | Optional. When missing or not set, defaults to `true` (cast is allowed). When **defined**: **boolean** — `true` = allow, `false` = skip this spell for this evaluation; **string** — Lua script run with `mq` and `EvalID` (current target spawn ID) in scope; return a truthy value to allow the cast, otherwise the spell is skipped (e.g. only cast when target HP > X%, or only when not in a certain zone). |

### Heal bands

Bands define **who** can receive the spell and **at what HP %**. Each band has two distinct concepts:

- **targetphase:** Phase stages at which this spell is considered. Only stage tokens go here: `corpse`, `self`, `groupheal`, `tank`, `pc`, `groupmember`, `mypet`, `pet`, `xtgt`. Spell-level **inCombat** (see [Special tokens](#special-tokens-targetphase)) controls whether corpse rez is allowed in combat; do not put `cbt` in targetphase.
- **validtargets:** Within a phase stage, which target types to consider. For **pc** or **groupmember** phases use class tokens (`war`, `clr`, etc.) or `all`. Absent or empty = treat as `all`. When the config is written, absent validtargets is written as `validtargets = { 'all' }`. **Corpse**, **tank**, and **self** need no validtargets.
- **min** / **max:** HP % range (0–100). The target’s HP must be in this range to be considered. For corpse-related targets the effective max is 200 (special).

**Phase order**

The **phase order** is the evaluation order within each pass. The bot runs **pass 1 (HP spells)** first, then **pass 2 (mana spells)** only if pass 1 found no cast. Within a pass, the bot evaluates phases in this sequence; for each phase it gets the list of targets for that phase and, for **each target**, checks all heal spells of that resource type that include that phase in their bands (in config order). The first spell that the target needs (HP in band, in range) is cast. The order is:

1. **corpse** (rez) — pass 1 only (HP pass)
2. **self**
3. **groupheal** (group AE)
4. **tank**
5. **groupmember** (in-group only)
6. **pc** (all peers)
7. **mypet**
8. **pet** (other pets)
9. **xtgt** (extended targets)

If a spell’s band includes multiple phases (e.g. `self`, `tank`, `pc`), the bot still follows this global phase order within the pass: it does not prefer one phase over another within the same spell. The first phase in the list above that has a valid, in-range target for that spell wins. The **Main Tank** is always the resolved tank (see [Tank and Assist Roles](tank-and-assist-roles.md)).

**Heal bands: behavior summary**

- **targetphase vs validtargets:** targetphase = at which phase stage; validtargets = what target types within that stage (classes for pc/groupmember only).
- **self vs pc:** Add `'self'` in targetphase for self-heals; they are evaluated before tank, groupmember, and pc (see evaluation order above).
- **tank:** No validtargets needed; main tank by role; `'tank'` alone in targetphase is enough.
- **groupheal vs groupmember:** **groupheal** = group AE heal (count group members in band, cast on group/self). **groupmember** = single-target heals only for characters in the bot’s (EQ) group; if no group member needs a heal, out-of-group PCs are not considered. Add **pc** in targetphase to also heal peers outside the group (evaluated after groupmember in the order above).
- **Selection:** For each phase within a pass, each target is checked against all heal spells of that resource type that have that phase; first spell (in config order) that the target needs is cast. Within pc/groupmember, targets are in iteration order (not lowest HP). Mana heals (`healResource = 'mana'`) are never considered until the HP pass completes without casting.

**Special tokens (targetphase):**
- **inCombat** (spell-level, not in targetphase) — When the spell has **corpse** in a band, set **inCombat** `true` on the spell entry to allow rez when there are mobs in the camp list. When `false` or unset, corpse rez is only considered when there are no mobs in camp (safe rez only). The GUI shows "Allow rez in combat" only when at least one band includes **corpse**.
- **xtgt** (extended target) — When in targetphase and **heal.xttargets** is set, the spell can target extended target (XTarget) slots; the band’s min/max apply to the XTarget’s HP.

**Heal over time (HoT)**

HoT spells are **autodetected** from spell data (SPA 100); no configuration is needed. The bot will not recast them on targets who already have the effect (buff or shortbuff). For **single-target** heals, a target is not considered to need the spell if they already have it. For **group heals**, when counting how many group members need the heal for **tarcnt**, members who already have the HoT are excluded; the group HoT is only cast when the number of members who are in HP band, in range, and do not already have the HoT is at least **tarcnt**. Group HoT **tarcnt** is most accurate when group members are peers (known via charinfo); non-peer group members are counted as “need” when in band if their buff state is unknown.

**Corpse rez eligibility:** When **corpse** is in targetphase, the bot only rezzes corpses whose player is in charinfo, in your EQ group, in your raid, or in your guild (same guild name as you). Random nearby corpses are ignored. Legacy `validtargets` on corpse bands (`all`, `bots`, `raid`) are ignored.

For a general overview of bands and targeting across spell sections, see [Spell targeting and bands](spell-targeting-and-bands.md).

### Peers and group

PC heal candidates come from **peers** (characters known via the actor net). Put **groupmember** in targetphase to heal only characters in the bot’s (EQ) group. Put **pc** in targetphase to also heal any peer in range (including out-of-group) when their HP is in the band. Peer **pets** are always considered from the full peer list (no group restriction). See [Out-of-group peers](out-of-group-peers.md) for how the bot interacts with peers who are not in your group.

**Example: single-target tank heal and group heal**

```lua
heal = {
  rezoffset = 0,
  interruptlevel = 0.80,
  xttargets = 0,
  spells = {
    {
      gem = 1,
      spell = 'Superior Healing',
      alias = 'cht',
      minmana = 0,
      minmanapct = 0,
      maxmanapct = 100,
      bands = {
        { targetphase = { 'self', 'tank', 'groupmember', 'pc' }, validtargets = { 'all' }, min = 0, max = 70 }
      }
    },
    {
      gem = 2,
      spell = 'Superior Group Heal',
      minmana = 0,
      minmanapct = 0,
      maxmanapct = 100,
      tarcnt = 2,
      bands = {
        { targetphase = { 'groupheal' }, validtargets = { 'all' }, min = 0, max = 80 }
      },
      precondition = true
    }
  }
}
```

---

## Runtime control

- **Toggle healing:** `/cz doheal on` or `/cz doheal off` (or `/cz doheal` to toggle).
- **Cast by alias:** `/cz cast <alias> [target]` — cast a heal spell by its alias. Use `/cz cast <alias> on` or `off` to enable or disable that spell’s use (**enabled**).
- **Add a spell slot:** `/cz addspell heal <position>` — insert a new heal entry at the given position (1 to count+1).

---

## Behavior summary

- **Corpse rez:** Spells with **corpse** in targetphase can target eligible corpses in range (charinfo peer, group member, raid member, or guild member). **rezoffset** skips the first N matching corpses. Rez is only considered when the spell’s band allows it and (for non-**cbt**) no mobs are in the camp list if the band is not combat.
- **Interrupt:** **interruptlevel** is used when deciding whether to interrupt the current cast for another heal (e.g. tank drop).
- **XT targets:** If **xttargets** lists slot numbers, spells with **xtgt** in bands can heal those extended target slots when their HP is in the spell’s band.
