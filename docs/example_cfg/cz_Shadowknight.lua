StoredConfig =  {
settings = {
  dodebuff = true,
  doheal = false ,
  dobuff = true,
  docure = false ,
  domelee = true,
  doraid = false ,
  dodrag = false ,
  domount = false ,
  mountcast = false ,
  dosit = false ,
  doforage = false ,
  sitmana = 90,
  sitendur = 90,
  sitaggro = 60,
  TankName = "automatic",
  TargetFilter = 1,
  petassist = true,
  acleash = 40,
  followdistance = 20,
  zradius = 100,
  campRestDistance = 10,
  maCampAnchor = true,
},
pull = {
  spell = {
    gem = "melee",
    spell = "",
  },
  radius = 700,
  zrange = 200,
  pullMinCon = 2,
  pullMaxCon = 7,
  maxLevelDiff = 6,
  usePullLevels = false ,
  pullMinLevel = 1,
  pullMaxLevel = 125,
  chainpullhp = 0,
  chainpullcnt = 0,
  mana = 60,
  manaclass = { 'CLR' },
  leash = 500,
  fteLockoutSec = 120,
  backupCandidates = 3,
  addAbortRadius = 50,
  usepriority = false ,
  hunter = false ,
  roam = true,
},
melee = {
  assistpct = 99,
  stickcmd = "hold uw 7",
  stayBehind = false ,
  behindAggroPct = 90,
  evadePct = 90,
  offtank = false ,
  mtSticky = false ,
  minmana = 0,
  otoffset = 0,
},
heal = {
  rezoffset = 0,
  interruptlevel = 0.8,
  xttargets = 0,
  spells = {
  },
},
buff = {
  spells = {
    {
      gem = 8,
      spell = "Restless Bones",
      alias = "pet",
      enabled = true,
      bands = {
        {
          targetphase = { 'self' },
          validtargets = { 'all' },
        },
      },
    },
    {
      gem = 7,
      spell = "Grim Aura",
      alias = "atkbuff",
      enabled = false ,
      bands = {
        {
          targetphase = { 'self' },
          validtargets = { 'all' },
        },
      },
    },
    {
      gem = 7,
      spell = "Vampiric Embrace",
      alias = false ,
      minmana = 0,
      enabled = true,
      bands = {
        {
          targetphase = { 'self' },
          validtargets = { 'all' },
        },
      },
      spellicon = 0,
    },
    {
      gem = 8,
      spell = "Augment Death",
      alias = "pethaste",
      minmana = 0,
      enabled = false ,
      bands = {
        {
          targetphase = { 'mypet' },
          validtargets = { 'all' },
        },
      },
      spellicon = 0,
    },
  },
},
debuff = {
  spells = {
    {
      gem = "ability",
      spell = "taunt",
      enabled = true,
      onlyMT = true,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
        },
      },
      delay = 0,
      precondition = "return mq.TLO.Me.TargetOfTarget.ID() and mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()",
    },
    {
      gem = "ability",
      spell = "bash",
      enabled = true,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
        },
      },
      delay = 0,
    },
    {
      gem = 3,
      spell = "Engulfing Darkness",
      alias = "snare",
      enabled = true,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
          min = 10,
          max = 60,
        },
      },
      delay = 0,
      dontStack = { 'Snared' },
    },
    {
      gem = 1,
      spell = "Lifedraw",
      alias = "lifetap",
      minmana = 20,
      enabled = true,
      onlyMT = true,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
          max = 99,
        },
      },
      delay = 0,
      precondition = "return mq.TLO.Me.PctHPs() < 80",
    },
    {
      gem = 4,
      spell = "Shroud of Pain",
      alias = "actap",
      enabled = true,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
        },
      },
      delay = 0,
    },
    {
      gem = 5,
      spell = "Torrent of Hate",
      alias = "atktap",
      enabled = false ,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
        },
      },
      delay = 0,
    },
    {
      gem = 2,
      spell = "Drain Soul",
      alias = false ,
      minmana = 0,
      enabled = false ,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
          min = 20,
          max = 100,
        },
      },
      recast = 0,
      delay = 0,
    },
    {
      gem = 6,
      spell = "Torrent of Fatigue",
      alias = false ,
      minmana = 0,
      enabled = false ,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = {  },
          min = 20,
          max = 100,
        },
      },
      recast = 0,
      delay = 0,
    },
  },
},
cure = {
  spells = {
  },
},
script = {
},
}
return StoredConfig