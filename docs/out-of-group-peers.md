# Out-of-group peers

This document explains how the bot interacts with **peers** who are not in the bot’s group: who counts as a peer, how the bot sees their state, and how healing, buffing, curing, corpse rez, and corpse dragging treat them.

## What is a peer?

A **peer** is any character known to the bot via the **actor net** (charinfo). Other bobblebot (or compatible) clients publish their character data (HP, buffs, detrimentals, pet state, etc.) to this shared state. The bot’s peer list is built from that data; peers do **not** have to be in the bot’s group. So you can have multiple bots in the same zone (or raid) on the same network, and they will see each other as peers even when they are in different groups.

## How the bot sees peers

The bot uses charinfo to know a peer’s current state without needing them in group: HP (`PctHPs`), buffs and short buffs, detrimentals (and cure-type counters), pet HP, and so on. That allows the bot to:

- Heal a peer when their HP is in the spell’s band (and in range).
- Cure a peer when they have a matching detrimental (and in range).
- Buff a peer when they need the buff and match the band (and in range).
- Rez or drag a peer’s corpse when the spell or drag logic allows it.

All of this works for peers who are outside the bot’s group, as long as the relevant configuration allows it (see below).

## Behavior by system

| System | Group restriction? | Out-of-group peers |
|--------|--------------------|--------------------|
| **Healing (PC)** | Only when **`groupmember`** is in the heal band’s **targetphase** (in-group only). | Put **`pc`** in **targetphase** to also heal any peer in range whose HP is in the band (HP from charinfo). See [Healing configuration](healing-configuration.md). |
| **Healing (pets)** | None. | Any peer’s pet in range with HP in band can be healed. |
| **Buffing** | **`groupmember`** = in-group only (incl. non-bot group members). **`pc`** = all peers. | Any peer in range that matches the band and needs the buff can be buffed. The **only** out-of-group **non-bot** PC we buff is the **explicitly configured tank** (TankName). See [Buffing configuration](buffing-configuration.md). |
| **Curing** | **`groupmember`** = in-group only (incl. non-bot group members via Group TLO). **`groupcure`** = group AE cure. **`pc`** = all peers. | Out-of-group peers can be cured in the **pc** pass. The **only** out-of-group **non-bot** PC we cure is the **explicitly configured tank** (TankName). See [Curing configuration](curing-configuration.md). |
| **Corpse rez** | Eligible if charinfo peer, group member, raid member, or guild member. | With **corpse** in targetphase, any eligible corpse in range can be rezzed (including out-of-group peers, groupmates, raidmates, and guildmates). |
| **Corpse drag** | None. | Any peer’s corpse in range can be dragged. See [Corpse dragging](corpse-dragging.md). |

## Configuration knobs

- **Heal bands:** Put **`groupmember`** in **targetphase** to restrict single-target heals to **characters in the bot’s (EQ) group**. Put **`pc`** in **targetphase** to also heal any peer in range (including out-of-group) when their HP is in the band. For heal (and buff), the groupmember-phase target list excludes self and the configured main tank; the pc-phase target list excludes the configured main tank (so the tank is only healed/buffed in the tank phase). Cure behavior is unchanged.
- **Cure bands:** Put **`groupmember`** in **targetphase** to cure in-group only (peers then non-peer group members by class). Put **`groupcure`** for group AE cure. Put **`pc`** to also cure any peer in range (out-of-group). The only out-of-group non-bot we cure is the explicitly configured tank.

For full details on bands and options, use the linked configuration documents above.
