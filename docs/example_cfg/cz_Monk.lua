StoredConfig =  {
settings = {
  dodebuff = true,
  doheal = true,
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
    spell = "Summoned: Shuriken of Quellious",
  },
  radius = 280,
  zrange = 50,
  pullMinCon = 2,
  pullMaxCon = 7,
  maxLevelDiff = 3,
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
  roam = false ,
},
melee = {
  assistpct = 99,
  stickcmd = "hold uw 7",
  stayBehind = true,
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
    {
      gem = "ability",
      spell = "Mend",
      alias = "men d",
      enabled = true,
      bands = {
        {
          targetphase = { 'self' },
          validtargets = { 'self' },
          min = 1,
          max = 30,
        },
      },
    },
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
      spell = "Flying Kick",
      enabled = true,
      bands = {
        {
          targetphase = { 'matar' },
          validtargets = { 'tanktar' },
          min = 1,
          max = 100,
        },
      },
      delay = 0,
    },
    {
      gem = "ability",
      spell = "Eagle Strike",
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