StoredConfig =  {
settings = {
  dodebuff = true,
  doheal = false ,
  dobuff = false ,
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
  petassist = false ,
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
  },
},
debuff = {
  spells = {
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
    },
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
      precondition = "return mq.TLO.Me.TargetOfTarget.ID() and mq.TLO.Me.TargetOfTarget.ID() ~= mq.TLO.Me.ID()",
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