# Bard Configuration

This document explains the nuances and considerations when configuring a **bard (BRD)** bot. The bot treats bards differently in several subsystems (buff targeting, casting, movement, melee, and MQ2Twist integration). This page summarizes what matters for configuration and what is automatic.

## Overview

- **Default twist (MQ2Twist):** Self buffs with numeric gems are sustained via a continuous twist derived from your buff config. The bot runs **noncombat** (idle) or **combat** twist depending on state; when it needs to cast something else (mez, cure, single spell), it stops twist, casts, then resumes.
- **Buff targeting:** For bards, only the **self** phase is used for buffs; the buff hook does **not** schedule single casts for self — the twist handles all self buffs. Use spell-level **inCombat** and **inIdle** to control which twist list each buff is in. Spell-level **combatOnly** applies only to non-bard auto buffs; bards should use **inCombat** / **inIdle** instead.
- **Interrupts:** The bot does not interrupt bard casts (buff, debuff, cure). No configuration required.
- **Movement and casting:** Bards can move, use nav, and stick while "casting"; the bot does not force a stop before casting.
- **Melee:** Before casting, if **domelee** is on and the bard is not in combat, the bot re-engages melee. Set **settings.domelee** if the bard should melee when not casting.
- **Debuffs:** **matar** debuffs are part of the **combat twist**. **notmatar** debuffs (mez, add-only) use a twist-once flow: target add → sing once → wait → re-target MA; optional re-apply timer (e.g. mez before duration ends).
- **Songs on/off:** **`/cz togglesongs`** or the Status tab **Songs** toggle stops all twist (session-only; default on when the bot starts). Use this to silence the bard without **`/czp`** (full bot pause). Not saved to the config file.

---

## Default twist (MQ2Twist)

When **MQ2Twist** is loaded and you are a bard, the bot maintains a default twist based on mode:

| Mode       | When used                             | Contents                                                                                                   |
| ---------- | ------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **idle**   | No mobs in camp (including pull travel) | All buffs with **inIdle** checked (config order). Skipped near primary bind (bind stealth). |
| **combat** | Mobs in camp, assisting (not pulling) | Buffs with **inCombat** checked (config order) then all debuff entries with **matar** and numeric gem (config order). |
| **travel** | Travel mode active (`/cz travel`)     | Single song: buff with alias `travel`, else `selos`; if neither, no twist. Config order.                   |

- The bot only issues `/twist` when the desired list differs from the current list or twist is stopped, so it does not restart the sequence every tick.
- **Item / alt** buffs are **not** in the default twist; they are cast normally (stop twist → cast → resume). To use clickies in a twist, configure the MQ2Twist INI (slots 21–40) and run `/twist` manually or combine with your list.

### Travel twist

When the bot is in **travel mode** (`/cz travel`), it uses the **travel twist**: a single song from **`config.buff.spells`** with alias **`travel`**, or if none, alias **`selos`**; if neither exists, no twist. For when travel mode is on and how to turn it off, see [Travel mode](travel-mode.md).

For full targeting and band details, see [Spell targeting and bands](spell-targeting-and-bands.md) and [Buffing configuration](buffing-configuration.md). For BRD, the self phase is handled by the MQ2Twist default twist when bardtwist is in use.

---

## Buff targeting and bands

For **BRD**, only **self** is evaluated for buffs; tank, groupbuff, groupmember, pc, mypet, and pet are **never** tried. The buff hook does **not** schedule a cast for self — the default twist (above) sustains all self buffs. Use spell-level **inCombat** and **inIdle** to control which twist list each buff is in; the two lists are **independent** (a song can be idle-only, combat-only, or both). Put **self** in your buff bands:

- **inIdle** (spell-level) — When `true` (default), this buff is in the **idle** twist list. When `false`, it is not twisted when no mobs are in camp. GUI shows "In idle" only for Bards.
- **inCombat** (spell-level) — When `true`, this buff is in the **combat** twist list. When `false` (default), it is not twisted when mobs are in camp.

### Example buff block (minimal)

Order of entries = order in the twist. Use **inCombat** and **inIdle** (spell-level) to control which list each song is in.

```lua
buff = {
  spells = {
    { gem = 1, spell = 'Selo\'s Sonata',     inCombat = false, inIdle = true,  bands = { { targetphase = { 'self' } } } },
    { gem = 2, spell = 'Kelin\'s Lucid Lament', inCombat = true,  inIdle = true,  bands = { { targetphase = { 'self' } } } },
    { gem = 3, spell = 'Psalm of Veeshan',   inCombat = false, inIdle = true,  bands = { { targetphase = { 'self' } } } },
  }
}
```

- Gem 1: in **idle** twist (inIdle true). Not in combat (inCombat false). Plays during pull travel when no mobs are in camp.
- Gem 2: in **combat** and **idle** twist (inCombat and inIdle both true).
- Gem 3: **idle** only (inIdle true, inCombat false); e.g. out-of-combat regen.

### Example debuff block (minimal)

**matar** = in combat twist. **notmatar** = twist-once (target add, sing once, re-target MA). Optional **bard.mez_remez_sec** for re-mez before duration ends.

```lua
debuff = {
  spells = {
    { gem = 4, spell = 'Requiem of Time', bands = { { targetphase = { 'matar' }, min = 1, max = 100 } } },
    { gem = 5, spell = 'Lullaby',         bands = { { targetphase = { 'notmatar' }, min = 90, max = 100 } } },
  }
}
```

- Gem 4: **matar** — plays in the combat twist on the MA target (e.g. slow).
- Gem 5: **notmatar** — mez on adds; bot uses twist-once (target add → sing once → re-target MA). Re-apply before mez wears if **config.bard.mez_remez_sec** is set.

---

## Song refresh

Songs are considered needing refresh when their duration is below about **6.1 seconds** (vs 24 seconds for other classes' buffs). There is no config option; this is informational only.

---

## Interrupts

The bot does **not** interrupt bard casts. The buff, debuff, and cure hooks all pass `skipInterruptForBRD`, so the bot will not stop a bard mid-cast to do something else. No configuration required.

---

## Movement and casting

Bards can move, use MQ2Nav, and stick while "casting." The **precast_wait_move** logic (stop nav/stick and wait before casting) is skipped for BRD, so the bard is not forced to stand still.

The **leash** check (return to camp when over leash) is **not** skipped for bards when casting. So the bard can still be called back to camp while singing. No config changes needed.

---

## Melee

The melee phase does **not** get the 5-second "moving_closer" deadline for bards that other classes get.

Before casting a spell, if **settings.domelee** is on, there are mobs in camp, the spell target is not a mez add (notmatar), and the bard is not in combat, the bot calls the combat logic to re-engage melee. So the bot tries to get the bard back into combat when about to cast a non-mez spell.

**Recommendation:** Set **settings.domelee** to `true` if you want the bard to melee when not casting.

---

## Twist stop and resume

Before any single cast (cure, debuff, or item/alt buff), the bot stops twist. When the cast completes (or is interrupted), the bot resumes the twist for the current mode (idle or combat). No configuration required.

---

## Pull: idle twist and engage song

When the bard is the puller:

- **During pull travel** (navigating out, returning to camp): The bot keeps the **idle** twist running (buffs with **inIdle** checked). No separate pull twist list.
- **When in range to aggro:** If **pull.spell** has a numeric **gem** (1–12), the bot runs `/twist once <gem>`. MQ2Twist sings that song once then reverts to the **idle** twist for the return run. The bard **stays stationary** at pull range (no moving toward the mob) until the song gets aggro or timeout; then the bot returns to camp.
- **When pull state clears:** The bot switches to the **combat** twist.

Configure in **pull.spell** (same block as the pull method): set **gem** to the spell gem (1–12) and **spell** to the agro song name. The bot uses this directly for twist-on-pull; there are no separate engage_gem/engage_spell options.

---

## notmatar debuffs (mez and add-only)

For **BRD**, **notmatar** debuffs (mez or any add-only debuff) do **not** use a normal cast. The bot:

1. Turns attack off and targets the add.
2. Runs **combat** twist as the “restore” list, then `/twist once <gem>` for the debuff song.
3. Waits for the cast to finish (MQ2Twist sings once then auto-resumes combat twist).
4. Updates debuff state and optionally sets a **re-apply timer** (see below).
5. Re-targets the MA.

**matar** debuffs are part of the **combat** twist and play in the normal twist cycle; no special flow.

### Re-apply timer (mez_remez_sec)

Optional **config.bard**:

- **mez_remez_sec** — Seconds before the notmatar debuff duration ends to re-apply (e.g. re-mez). Default **6** if omitted. Applies to any notmatar debuff with a duration (e.g. mez). When the timer expires, the bot will target that add again and run the twist-once flow.

The re-apply timer is set **whenever** the notmatar twist-once wait ends (when the bot stops waiting for the song to finish), even if song start was not detected (e.g. so adds still get re-mezzed). Only the “target is mezzed” debuff state is skipped when the song was never seen. When the mez spell has no duration in spell data, re-apply uses a fixed **12 second** interval so adds stay mezzed until the MA engages them.

---

## Mez and melee (known limitation)

When mezzing a **notmatar** (an add), the bot turns attack off, targets the add, and uses the twist-once flow. After the cast it re-targets the MA. The bard may not re-engage melee until the add is dead or mez is cleared; be aware when using a bard for mezzing.

---

## Debuff completion

The "already on target" and resist handling for debuffs treat bards specially (e.g. **MissedNote** is considered so the bot can still mark a debuff as complete appropriately). Your debuff config (bands, recast, delay, etc.) is unchanged; this is internal behavior only.

---

## Summary

| Area              | What to do                                                                                                                                                                                                                                         |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Buffs**         | Use **self** in bands. Tank, groupbuff, groupmember, pc, mypet, pet have no effect for bards. Self buffs are sustained by the default twist. Use **inIdle** / **inCombat** (GUI) to control twist lists.                                                            |
| **Default twist** | Idle = inIdle buffs (not near bind; includes pull travel); combat = inCombat buffs + matar debuffs. Item/alt buffs are cast normally; for clickies in twist use MQ2Twist INI. Bind stealth stops idle twist near primary bind. |
| **Pull**          | Idle twist continues during pull travel. Use **pull.spell** with a numeric **gem** (and **spell** name) for the agro song.                                                                                                         |
| **Debuffs**       | **matar** → in combat twist. **notmatar** (mez, add-only) → twist-once flow; optional **bard.mez_remez_sec** (default 6) to re-apply before duration ends. See [Debuffing](debuffing-configuration.md) and [Mezzing](mezzing-configuration.md). |
| **Cures**         | No special config; twist stops then resumes after cast.                                                                                                                                                                                            |
| **Interrupts**    | Automatic; the bot does not interrupt bard casts.                                                                                                                                                                                                  |
| **Movement**      | Automatic; bards can move while casting.                                                                                                                                                                                                           |
| **Melee**         | Set **settings.domelee** if you want the bard to re-engage melee when not casting.                                                                                                                                                                 |
| **Twist**         | Automatic; twist is stopped before any single cast and resumed when the cast completes.                                                                                                                                                            |
