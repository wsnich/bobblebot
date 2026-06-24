# Automatic MA and MT Selection

This document explains how CZBot resolves **Main Assist (MA)** and **Main Tank (MT)** when `AssistName` or `TankName` is set to **`"automatic"`**. It covers game role sources, **`ma_list`** / **`mt_list`** fallback lists, availability rules, **`maAnchorLeash`**, multi-box editing, and debugging.

For what the MA and MT *do* once resolved (target picking, heals, offtank, puller), see [Tank and Assist Roles](tank-and-assist-roles.md).

---

## Overview

| Setting | Config path | Runtime command |
|---------|-------------|-----------------|
| Main Tank | `settings.TankName` | `/cz tank <name>` or `/cz tank automatic` |
| Main Assist | `settings.AssistName` | `/cz assist <name>` or `/cz assist automatic` |

**Values:**

- **Character name** — Always use that PC.
- **`"automatic"`** — Resolve from EQ group/raid roles, then fallback lists (this document).
- **`"manual"`** — No default; set at runtime with `/cz tank` or `/cz assist`.

**Key points:**

- Resolution is **live** — every heal, assist sync, and role check re-evaluates. The Status tab shows the current resolved name with `(auto)` when the setting is `"automatic"`.
- **MA and MT resolve independently.** If `AssistName` is unset, it defaults to `TankName` at load, but when both are `"automatic"`, MA still comes from group/raid Main Assist (+ `ma_list`) and MT from group Main Tank (+ `mt_list`). They are not forced to be the same person.
- **`TankName` defaults to `"automatic"`** in new configs. Populate **`ma_list`** and **`mt_list`** in `cz_common.lua` (or the Roles GUI) for reliable multibox fallback.

---

## Resolution flow

```mermaid
flowchart TD
    subgraph ma [AssistName automatic]
        MA1{In raid?}
        MA1 -->|Yes| MA2[Raid.MainAssist]
        MA1 -->|No| MA3[Group.MainAssist]
        MA2 --> MA4{Alive and in zone?}
        MA3 --> MA4
        MA4 -->|Yes| MAResolved[Resolved MA]
        MA4 -->|No| MA5[Walk ma_list in order]
        MA5 --> MA6{First alive in zone within maAnchorLeash?}
        MA6 -->|Yes| MAResolved
        MA6 -->|No| MANone[No MA resolved]
    end
    subgraph mt [TankName automatic]
        MT1{In raid?}
        MT1 -->|Yes| MT5[Walk mt_list in order]
        MT1 -->|No| MT2[Group.MainTank]
        MT2 --> MT4{Alive and in zone?}
        MT4 -->|Yes| MTResolved[Resolved MT]
        MT4 -->|No| MT5
        MT5 --> MT6{First alive in zone within maAnchorLeash?}
        MT6 -->|Yes| MTResolved
        MT6 -->|No| MTNone[No MT resolved]
    end
```

---

## Game role sources (group vs raid)

| Role | Not in raid | In raid |
|------|-------------|---------|
| **MA** | `Group.MainAssist` | `Raid.MainAssist` |
| **MT** | `Group.MainTank` | *(not used — see below)* |

In a **raid**, the EQ UI has no raid-wide Main Tank or Puller; those always come from the **group** window for puller/MT assignment in other contexts. For **automatic MT resolution**, CZBot **ignores** `Group.MainTank` entirely when `Raid.Members > 0` and uses **`mt_list` only**. See [Raid mode](raid-mode.md).

For **automatic MA resolution** in a raid, CZBot uses **`Raid.MainAssist`** first, then **`ma_list`**.

---

## Primary vs fallback

### Primary (EQ-assigned role)

When the game reports a Main Assist or Main Tank name:

1. Name must be non-empty.
2. Candidate must be **alive** and in the **same zone** as this bot.
3. **No distance check** — a primary who is alive in-zone but far away is still used.

If the primary is dead, feigned, hovering, or in another zone, resolution skips to the fallback list.

### Fallback (`ma_list` / `mt_list`)

When no primary is available (or in raid for MT):

1. Walk the list **in order** — first eligible name wins.
2. Candidate must be **alive** and in the **same zone**.
3. Candidate must be within **`maAnchorLeash`** of this bot.

**Common gotcha:** If the EQ-assigned MA is alive in your zone but 200 units away, bots still follow that MA. List entries only matter when the primary fails the alive/in-zone check (or for MT in raid).

---

## Availability criteria

CZBot looks up each candidate via **MQCharInfo** (bot peers) or **Spawn TLO** (non-bot PCs).

| Check | Primary (game role) | Fallback (list) |
|-------|---------------------|-----------------|
| Alive | Yes | Yes |
| Same zone | Yes | Yes |
| Within `maAnchorLeash` | No | Yes |

**Alive (MQCharInfo peer):**

- `State` must not include `DEAD`, `FEIGN`, or `HOVER`.
- `PctHPs` must be `> 0` when known.

**Alive (Spawn fallback for non-bot PCs):**

- Spawn is not dead and not hovering.

**Same zone (MQCharInfo):**

- `Zone.Distance` is non-nil (plugin reports distance only for peers in your zone).

**Same zone (Spawn fallback):**

- Assumed true when spawn exists.

---

## `ma_list` and `mt_list`

Stored **top-level** in **`cz_common.lua`** (shared by all bots on that MacroQuest install). At runtime, each bot mirrors them as **`MaList`** and **`MtList`** in runconfig.

**Order = priority.** Put your preferred MA/MT bot first; the first name that passes availability wins.

**Example `cz_common.lua` snippet:**

```lua
ma_list = { "MaBot", "BackupMa" },
mt_list = { "TankBot", "OfftankBot" },
```

There are **no `/cz` add/remove commands** for these lists (unlike exclude, priority, or charm). Edit via the GUI or by hand in `cz_common.lua`.

---

## Editing lists and multi-box sync

**GUI:** `/czshow` → **Roles** tab

- **Main Assist fallback list (`ma_list`)** — ordered PC names.
- **Main Tank fallback list (`mt_list`)** — ordered PC names.
- Add via **Add target** (PC targeted) or **Add** (type name). Reorder with **Up** / **Down**. **Remove** deletes an entry.
- Changes auto-save to `cz_common.lua`.

**After editing on one bot**, run **`/cz reloadcommon`** on every other bot sharing the same `cz_common.lua` so runtime lists match disk.

**Save behavior:**

- **Add** — union-merge with disk (existing entries kept, new names appended).
- **Reorder / remove** — replace list on disk with the current order.

---

## `maAnchorLeash`

**Default chain:** `settings.maAnchorLeash` → `settings.acleash` → `75`

Editable on the Roles tab (**MA leash**). Can also be set at runtime (persists to char config).

**Used for three features:**

1. **List fallback** — max distance for `ma_list` / `mt_list` candidates.
2. **MA camp anchor** — when `maCampAnchor` is on, mob bubble centers on the resolved MA within this distance.
3. **Combat target inject** — when `maCampAnchor` is on, injects the MA's (then MT's) ATTACK target into MobList if the leader is within leash.

`maCampAnchor` is separate from automatic resolution but shares the leash setting. See [Tank and Assist Roles — MA-anchored mob bubble](tank-and-assist-roles.md#ma-anchored-mob-bubble).

---

## Configuration examples

### Typical multibox (group)

```lua
-- Per-char config (each bot)
settings = {
  TankName = "automatic",
  AssistName = "automatic",  -- or omit; defaults to TankName
  maCampAnchor = true,
  acleash = 40,
}
```

```lua
-- cz_common.lua (shared)
ma_list = { "WarriorMa", "MonkBackup" },
mt_list = { "WarriorMa", "SkOfftank" },
```

- Assign **Main Assist** and **Main Tank** in the EQ group window (human or lead bot).
- Lists provide fallback when the assigned role holder dies, zones, or is unavailable.

### Raid

- Set **Raid Main Assist** in the EQ raid window.
- Maintain **`mt_list`** with your heal priority — automatic MT does **not** use group Main Tank in raid.
- **`ma_list`** still applies when raid MA is unavailable.

### Legacy: everyone assists the tank

```lua
settings = {
  TankName = "MyTank",
  -- AssistName unset → defaults to "MyTank"
}
```

No automatic resolution or fallback lists involved. Both roles resolve to `MyTank`.

---

## Runtime commands and debugging

| Command / UI | Purpose |
|--------------|---------|
| `/cz tank automatic` | Set MT to automatic for this session (runtime runconfig). |
| `/cz assist automatic` | Set MA to automatic for this session. |
| Status tab | Shows resolved Assist Name and Tank Name; `(auto)` suffix when setting is automatic. |
| `/cz reloadcommon` | Reload `cz_common.lua` and refresh `ma_list` / `mt_list` mirrors. |
| `/cz mobfilter` | Prints MA distance, `inAttack`, target ID, and inject eligibility for the selected spawn. |

`/cz tank` and `/cz assist` with a fixed name override automatic for the session only; char config file is unchanged unless you use `setvar` or edit the file.

---

## Downstream effects

Once MA and MT names are resolved:

- **Healers** target the resolved **MT** (tank phase). See [Healing configuration](healing-configuration.md).
- **DPS** syncs to the resolved **MA** at **assistpct**. See [Tanking configuration](tanking-configuration.md).
- **`AmIMainAssist`** — this bot runs camp target picking (`selectMATarget`). See [Tank and Assist Roles](tank-and-assist-roles.md).
- **`AmIMainTank`** — separate MT follow rules, `mtSticky`, `onlyMT` debuffs. See [Offtank configuration](offtank-configuration.md).
- **Debuff bands** (`matar`, `notmatar`) use resolved MA/MT targets. See [Debuffing configuration](debuffing-configuration.md).

---

## See also

- [Tank and Assist Roles](tank-and-assist-roles.md) — role behavior, mtSticky, puller, offtank
- [Raid mode](raid-mode.md) — raid save/load and raid UI role limits
- [Commands and configuration reference](commands-and-configuration-reference.md) — `/cz tank`, `/cz assist`, `reloadcommon`
- [setvar reference](setvar-reference.md) — `settings.TankName`, `settings.AssistName`, `settings.maCampAnchor`, `settings.maAnchorLeash`
