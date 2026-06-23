# Tank and Assist Roles

This document explains how to configure **Main Tank (MT)**, **Main Assist (MA)**, and **Puller**, and how each bot behaves in different scenarios.

## Overview

- **Main Tank (MT)**  
  The character who receives **heals** (healers prioritize this person) and who is allowed to **pick from the mob list** to start engagements when that character is a bot. Only the MT bot chooses which mob to engage from the camp list (with puller priority).

- **Main Assist (MA)**  
  The character whose **target** all DPS and offtank follow. When you say “assist,” bots attack whatever the MA has targeted. The **`/cz attack`** command engages the MA’s target **immediately** (ignores assist-at %) and keeps that engagement until the target dies or you run `/cz abort`, turn off domelee, or issue another `/cz attack`.

- **Puller**  
  Set in the game (group window). When the MT is a bot and TankName is set to `"automatic"`, the MT bot prefers the **Puller’s target** when choosing which mob to engage from the camp list (e.g. the mob the puller is bringing in).

Heals always go to the MT. DPS and offtank behavior follow the MA (or the MA’s target). When MT and MA are different, the offtank logic depends on whether they are on the same mob or not (see Offtank below).

---

## How to Configure

### TankName (Main Tank)

- **Where:** Config file under `settings.TankName`, or at runtime with `/cz tank <name>` or `/cz tank automatic`.
- **Values:**
  - **Character name** — e.g. `Warriorname`. This character is the Main Tank; healers focus on them, and if this bot is that character, it picks from the mob list.
  - **`"manual"`** — No default MT; set at runtime with `/cz tank SomeName`.
  - **`"automatic"`** — Use the **group’s Main Tank** role (from the group window) when not in a raid; if the assigned MT is dead, hovering, or not in zone, fall back to **`mt_list`** in cz_common (first alive, in-zone name within **MA leash**). In a **raid**, there is no raid Main Tank — automatic mode uses **`mt_list`** directly (same proximity rules).

Healers always use the resolved MT. Only the character who is the MT (when a bot) picks from the mob list and uses puller priority.

### AssistName (Main Assist)

- **Where:** Config file under `settings.AssistName`, or at runtime with `/cz assist <name>` or `/cz assist automatic`.
- **Values:**
  - **Character name** — This character is the Main Assist; DPS and offtank follow their target. **`/cz attack`** engages the MA’s target immediately (ignores assist-at %).
  - **`"manual"`** — No default MA; set at runtime with `/cz assist SomeName`.
  - **`"automatic"`** — Use **raid Main Assist** when in a raid, otherwise **group Main Assist**. If the assigned MA is dead, hovering, or not in zone, fall back to **`ma_list`** in cz_common (first alive, in-zone name within **MA leash**).

If you do **not** set AssistName (leave it unset or empty), the bot treats it as the same as TankName so that “everyone assists the tank” (backward compatible).

### Puller

- **Where:** Set in the **game group window** (right‑click group member, assign Puller). There is no bot config for the puller.
- **Effect:** When TankName is `"automatic"` and this bot is the MT, it prefers the Puller’s current target when choosing which mob to engage from the camp list.

---

## Config and Roles (Mermaid)

```mermaid
flowchart LR
    subgraph config [Config]
        TankName[TankName]
        AssistName[AssistName]
    end
    subgraph resolved [Resolved]
        MT[Main Tank]
        MA[Main Assist]
    end
    TankName --> MT
    AssistName --> MA
    style MT fill:lightblue
    style MA fill:lightgreen
```

When **automatic**:

- **MT** = Group.MainTank when not in a raid (if available); in raid, or when primary MT unavailable → **`mt_list`** fallback (proximity-gated).
- **MA** = Raid.MainAssist when in raid, else Group.MainAssist; when primary MA unavailable → **`ma_list`** fallback (proximity-gated).
- **Puller** = Group.Puller (raid has no Puller; always from group).

Resolution is **stateless** — recomputed every main-loop tick (~100ms) from live group/raid roles, availability (alive, in zone), and list order. No cached MA/MT name between ticks.

---

## Who Does What (Mermaid)

```mermaid
flowchart TB
    subgraph roles [Bot role]
        MTBot[MT bot]
        MABot[MA bot]
        DPS[DPS bot]
        OT[Offtank bot]
        Heal[Healer]
    end
    MTBot -->|"Pick from MobList, puller priority"| Engage
    MABot -->|"Sticky target; named override"| Engage
    DPS -->|"Assist MA target"| Engage
    OT -->|"Add or tank MA target"| Engage
    Heal -->|"Always heal MT"| MT
```

- **MT bot:** Picks which mob to engage from the mob list (closest LOS, puller’s target preferred when applicable).
- **MA bot:** Chooses its own target from the mob list. On initial pick: **named** mobs first, then closest engageable (with mez/distance rules). Once engaged, **sticks** to that target until it dies; the only mid-fight switch is when a **named** enters camp while the MA is on a non-named mob.
- **DPS bot:** Syncs to the MA’s target (assists the MA).
- **Offtank bot:** See next diagram.
- **Healer:** Always prioritizes the MT (no MA in heal logic).

---

## Offtank Decision (Mermaid)

```mermaid
flowchart LR
    A[MT target vs MA target] --> B{Same mob?}
    B -->|Yes| C[Pick an add]
    B -->|No| D[Tank MA target]
    C --> E[engageTargetId = add]
    D --> F[engageTargetId = MA target, agro/taunt]
```

- **MT target == MA target (same mob):** Offtank picks an **add** (Nth other mob in the list, via `otoffset`).
- **MT target != MA target (different mobs):** Offtank **tanks the MA’s target** (sets engage target to MA’s target and uses agro/taunt).

---

## Scenarios (Plain English)

### All bots assist the same person (legacy)

- Set **TankName** to that character’s name.
- Leave **AssistName** unset (or set it to the same as TankName).
- Everyone assists the tank; heals go to the tank. Behavior matches the old “single tank” setup.

### Human is Main Assist

- Set **TankName** to the MT (can be a bot or human).
- Set **AssistName** to the human’s name.
- All bots assist the human’s target; heals go to the MT. The human directs which mob the group DPSes (e.g. event logic: kill adds first, keep one mob tanked). No special MA-bot logic runs.

### Bot is Main Tank

- Set **TankName** to this bot’s name (or use `"automatic"` and assign this bot as group MT in the group window).
- This bot picks from the mob list and prefers the **Puller’s target** when the camp list is used and a puller is set.

### Bot is Main Assist (different from MT)

- Set **AssistName** to this bot’s name (or `"automatic"` and assign this bot as group/raid MA).
- This bot chooses its own target from the mob list (**named** first on initial pick, then closest engageable). It **sticks** to that target until it dies, switching mid-fight only when a **named** enters camp while on a non-named mob. Other DPS and offtank follow this bot’s target.

### Offtank bot

- Set **offtank** to true (config or `/cz offtank on`) and set **AssistName** (MA).
- If MT and MA are on the **same** mob, offtank picks an **add** (Nth other mob).
- If MT and MA are on **different** mobs, offtank **tanks the MA’s target** (agro/taunt).

### Automatic mode

- Set **TankName** and/or **AssistName** to **`"automatic"`**.
- The bot uses the **group** (or **raid** for MA) window roles first, then **`ma_list`** / **`mt_list`** from **cz_common.lua** when the assigned role is unavailable.
- **Primary** (group/raid assigned): must be alive and in zone; no distance check (puller MA can be outside camp).
- **List fallback**: must be alive, in zone, and within **`maAnchorLeash`** of this bot (defaults to **Radius** / `acleash`). Distant groups sharing the same list do not steal assist when a local MA dies until someone on the list enters range.

Raid has no Main Tank or Puller in the game UI. In raid, automatic MT skips group Main Tank and uses **`mt_list`** only.

---

## MA/MT fallback lists (cz_common)

Global ordered lists in **cz_common.lua** (not per-zone):

- **`ma_list`** — Main Assist fallback when automatic MA is unavailable.
- **`mt_list`** — Main Tank fallback when automatic MT is unavailable (or in raid).

Edit in the GUI **Roles** tab. After editing, run **`/cz reloadcommon`** on other bots so runtime lists match disk.

Order matters: the first name that passes availability checks wins. Put local backups before other groups’ MAs if you share one list across independent camps in the same zone.

---

## MA-anchored mob bubble

When **`settings.maCampAnchor`** is on (default), DPS/support bots center their **mob list** (`# Mobs`) on the **Main Assist** when the MA is nearby, instead of only the camp pin.

- **Anchor:** Uses charinfo `Zone.X/Y/Z` for bot MAs (Spawn TLO fallback for human MAs). MA must be within **`maAnchorLeash`** of this bot (defaults to **Radius** / `acleash`). If the MA is farther away (e.g. out pulling), the bubble falls back to the camp pin or player position.
- **Combat inject:** When the MA's charinfo `State[]` includes **`ATTACK`** (auto-attack on; often alongside `STAND`, `GROUP`, etc.) and the MA has an NPC target, that target is added to MobList even if it failed normal area/LoS filters. MT is used as fallback when MA has no injectable target.
- **Commands:** `/cz macampanchor on|off`, `/cz maanchorleash <n>`, `/cz mobfilter [id]` for diagnostics.
- **GUI:** **Roles** tab — **MA anchor** checkbox and **MA leash**; Status tab **Camp** section still shows `# Mobs` with `[MA]`, `[Camp]`, or `[Self]` for the active scan center. **`maAnchorLeash`** also gates **`ma_list`** / **`mt_list`** fallback distance.

Pull radius and camp-return leash are **not** affected — only the combat/debuff mob bubble follows the MA.
