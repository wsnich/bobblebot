# Hook: chchainTick

**Priority:** 500  
**Provider:** lib.chchain

## Logic

The hook only runs when runState is **chchain**. CH chain is started by the **OnGo** event (e.g. "Go NextChar>>"); the tick then waits for cast to finish or deadline, then passes the turn with /rs.

```mermaid
flowchart TB
    Start[chchainTick] --> State{runState == chchain?}
    State -->|No| End[return]
    State -->|Yes| Payload{payload.chnextclr?}
    Payload -->|No| Clear[clearRunState, return]
    Payload -->|Yes| Fizzle{Cast.Result == CAST_FIZZLE?}
    Fizzle -->|Yes| Recast[/cast Complete Heal, return]
    Fizzle -->|No| Corpse{CastTimeLeft > 0 and target corpse?}
    Corpse -->|Yes| Interrupt[/rs interrupt, /rs Go chnextclr, clearRunState]
    Corpse -->|No| Deadline{mq.gettime() >= deadline?}
    Deadline -->|Yes| Pass[/rs Go chnextclr, clearRunState]
    Deadline -->|No| Sit{not sitting and not casting? /sit on}
    Sit --> End2[return]
```

**OnGo (event):** When the Go message is for this character and dochchain is on: validate tank (chtanklist); if tank dead/zoned advance to next tank and set chchain state with deadline. Target tank, check mana and range; if ok /cast "Complete Heal" and setRunState('chchain', { deadline, chnextclr, priority }). Otherwise set state with deadline and skip (e.g. out of mana, out of range).

## See also

- [CHChain configuration](../chchain-configuration.md) — operator setup and commands
- [README](README.md)
- [Run state machine](run-state-machine.md)
- [Events](events.md) — chchain registers its own events
