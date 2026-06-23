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
  mountcast = "none",
  dosit = true,
  doforage = false ,
  sitmana = 90,
  sitendur = 90,
  TankName = "manual",
  TargetFilter = 1,
  petassist = false ,
  acleash = 100,
  followdistance = 35,
  zradius = 75,
  campRestDistance = 15,
},
pull = {
  spell = {
    gem = "melee",
    spell = "",
  },
  radius = 400,
  zrange = 150,
  pullMinCon = 2,
  pullMaxCon = 5,
  maxLevelDiff = 6,
  usePullLevels = false ,
  pullMinLevel = 1,
  pullMaxLevel = 125,
  chainpullhp = 0,
  chainpullcnt = 0,
  mana = 60,
  manaclass = { 'CLR', 'DRU', 'SHM' },
  leash = 500,
  addAbortRadius = 50,
  usepriority = false ,
  hunter = false ,
},
melee = {
  assistpct = 99,
  stickcmd = "hold uw 7",
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
      spell = "Unified Righteousness",
      alias = false ,
      minmana = 0,
      enabled = true,
      inCombat = false ,
      inIdle = true,
      combatOnly = false ,
      bands = {
        {
          targetphase = { 'self' },
          validtargets = { 'all' },
        },
      },
      spellicon = 58636,
    },
  },
},
debuff = {
  spells = {
    {
      gem = 10,
      spell = "Unyielding Censure",
      alias = false ,
      minmana = 0,
      enabled = true,
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