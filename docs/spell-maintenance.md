# Spell maintenance

CZBot can keep your **gem bar**, **spellbook**, and **config spell names** in sync during downtime so combat does not stall on mid-fight memorization or stale spell ranks.

---

## Pre-memorize (premem)

**Setting:** **`settings.premem`** (default `true`). Combat tab checkbox or **`/cz premem on|off`**.

During downtime (out of combat, no mobs in camp, not casting or moving), the bot scans configured heal/buff/debuff/cure spells and the pull spell. For each **gem assigned to exactly one** spell, if the wrong spell is memorized it issues **`/memspell`** — **one gem per misc tick**, with a short wait after each memorize.

Gems shared by multiple configured spells (multiplexed buffs, etc.) are left alone so on-demand swapping still works.

**Debug:** **`/cz prememdebug on`**

After **`/cz applyupgrade`**, premem is nudged to re-check on the next safe tick so upgraded spell names load into their gems.

---

## Auto-scribe

**Setting:** **`settings.autoScribe`** (default `true`). **`/cz autoscribe on|off`**.

On level-up, the bot flags new scrolls to scribe and processes **one scroll per misc tick** when safe (out of combat, no camp mobs). This avoids blocking the main loop during long scribe sessions.

**Manual scribe:** **`/cz scribe`** — scans all packs immediately (blocking; downtime only). Auto-confirms EQ's replace dialog. When finished, runs the upgrade detector.

---

## Spell upgrades

**Setting:** **`settings.upgradeCheck`** (default `true`).

The bot compares configured spell names to the **highest scribed rank** in your spellbook per **SpellGroup** (MQ TLO). When a better rank exists, it surfaces suggestions on the **Status** tab and via:

- **`/cz upgrades`** — numbered list of pending upgrades
- **`/cz applyupgrade <n>`** — apply one upgrade (rewrites config spell name + saves)
- **`/cz applyupgrade all`** — apply all pending

Background re-scan runs on a slow cadence during downtime and after level-up. Scribe completion also triggers a scan.

**Debug:** **`/cz upgradedebug on`**

Spells with **SpellGroup 0** (missing data on some servers) are skipped to avoid false positives.

---

## See also

- [Commands and configuration reference](commands-and-configuration-reference.md) — full command list
- [Debuffing configuration](debuffing-configuration.md#burn-window) — burn window for timed burn spells
- [setvar reference](setvar-reference.md) — **`settings.premem`**, **`settings.autoScribe`**, **`settings.upgradeCheck`**
