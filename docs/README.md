# CZBot Documentation Index

Short index of all documentation pages. Use this to find the right doc for configuring healing, tanking, pulling, buffing, debuffing, curing, pets, nuking, mezzing, and melee combat abilities.

---

## Role and combat


| Document                                          | Description                                                                                                                   |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [Tank and Assist Roles](tank-and-assist-roles.md) | How to configure Main Tank (MT), Main Assist (MA), and Puller; who gets heals, who picks targets, and how DPS/offtank follow. |
| [Automatic MA/MT Selection](automatic-ma-mt-selection.md) | How `automatic` TankName/AssistName resolves: game roles, `ma_list`/`mt_list` fallback, `maAnchorLeash`, and multi-box editing. |
| [Tanking configuration](tanking-configuration.md) | Melee/tank settings: stick command, assist %, camp leash, and links to roles and pull.                                        |
| [Offtank configuration](offtank-configuration.md) | How to configure an offtank: same target (pick add) vs different target (tank MA’s target).                                   |
| [Safety and stealth](safety-and-stealth.md) | Protected NPCs (soulbinder/translocator), bind-point stealth, and configurable no-combat zones in cz_common.                |


## Pulling and movement


| Document                                              | Description                                                                                                                             |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [Pull Configuration and Logic](pull-configuration.md) | How pulling works: config options, when the bot starts a pull, pre-conditions, hunter mode, runtime commands (xarc, exclude, priority). |
| [Corpse dragging](corpse-dragging.md)                 | Automatic drag of peer corpses (dodrag); draghack uses sumcorpse.                                                                      |


## Raid


| Document                          | Description                                                                                                      |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| [Raid mode](raid-mode.md)         | What the doraid toggle does (raid mechanic mode), raid save/load commands, and how they affect bot behavior.   |


## Spells and effects


| Document                                              | Description                                                                                               |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| [Healing configuration](healing-configuration.md)     | Heal spells, bands (who and at what HP), rez, interrupt, XT targets, commands.                            |
| [CHChain configuration](chchain-configuration.md)     | Complete Heal chain rotation across clerics: setup, start, tank/pause control, and `/rs` coordination.   |
| [Buffing configuration](buffing-configuration.md)     | Buff spells, bands (self, tank, validtargets, mypet, pet), spellicon, combat vs idle, **combatOnly** (non-bard short buffs). Pet summon auto-detected.                  |
| [Debuffing configuration](debuffing-configuration.md) | Debuff spells, bands (matar, notmatar, named), Charm list (per-zone), recast, delay; links to nuking and mezzing. |
| [Spell targeting and bands](spell-targeting-and-bands.md) | Targeting logic and band tags for all spell types (heal, buff, debuff, cure); evaluation order, tarcnt, matar/notmatar. |
| [Curing configuration](curing-configuration.md)       | Cure spells, curetype (all / poison / disease / curse / corruption), priority phase, bands.                 |
| [Bard configuration](bard-configuration.md)            | Class-specific behavior for bards: buff targeting (self only), movement while casting, interrupts, melee re-engage, twist, and mez limitation. |
| [Out-of-group peers](out-of-group-peers.md)            | Who counts as a peer, how healing, buffing, curing, and corpse drag treat peers outside your group.      |


## Nuking and mezzing (first-order)


| Document                                          | Description                                                                            |
| ------------------------------------------------- | -------------------------------------------------------------------------------------- |
| [Nuking configuration](nuking-configuration.md)   | How to set up nuking: configure nukes as debuffs (matar, notmatar).                 |
| [Mezzing configuration](mezzing-configuration.md) | How to set up mezzing: configure mez as debuffs (notmatar, Charm list), level limits. |
| [Melee combat abilities](melee-combat-abilities.md) | How to set up melee combat abilities: configure disciplines and /doability as debuffs (gem disc/ability); domelee + dodebuff. |
| [Spell maintenance](spell-maintenance.md) | Pre-memorize gembar, auto-scribe on ding, spell-upgrade detection and apply. |


## Pets


| Document                                    | Description                                                                   |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| [Pets configuration](pets-configuration.md) | Pet summon (auto-detected), petassist, pet buffing, charm (link to debuff). |


## Bot logic (state and flow)


| Document | Description |
| -------- | ----------- |
| [Bot logic](botlogic/README.md) | Charts state and decision logic so you can trace the flow of any bot action; main loop, run state machine, hooks, events, spell casting, and movement. |


## Reference


| Document                                                                        | Description                                                         |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [Commands and configuration reference](commands-and-configuration-reference.md) | Full list of /cz commands and all config file options in one place. |
| [setvar reference](setvar-reference.md)                                         | All /cz setvar paths (section.key), types, defaults, and purpose.   |


