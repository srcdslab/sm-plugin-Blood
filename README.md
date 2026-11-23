# Blood

SourceMod plugin for Counter-Strike: Source that adds more blood: 3D blood particles on hits, a
spurt on headshots, blood splattered on the walls behind the victim and a pool of blood where a
player dies.

Written for 64-bit CS:S servers: pure SourcePawn, no extension, no gamedata of its own. It uses
SDKHooks (`TraceAttack`, `OnTakeDamage_Alive`), whose offsets ship with SourceMod for `linux` and
`linux64`, and stock temp entities. Clients download nothing: the particle systems and decals
come with the game.

## How it works

- **Hit particles**: each hit plays the children of the `blood_impact_red_01` particle system
  (`_mist`, `_goop`, `_smalldroplets`) at the hit point, oriented along the shot so the blood leaves the victim on the
  far side. Hits without a hit point (fall damage, grenades, world damage) bleed upwards from the
  middle of the body.
- **Headshots**: `blood_advisor_pierce_spray` adds a stream of red droplets for about 1.5 s,
  and the wall behind gets twice as many decals.
- **Wall splatter**: for a bullet or knife hit from another player, the plugin traces from the hit
  point along the shot, from the attacker's eyes through the victim, for `sm_blood_wall_distance`
  units. If it reaches a world surface (wall or floor), it puts `sm_blood_wall_decals` blood decals
  there (`World Decal` temp entity with a random `decals/blood1` to `decals/blood6`). Self-damage,
  world and fall damage never splatter walls.
- **Death**: two `blood_impact_red_01_goop` splashes, `_mist` and `_droplets` burst from the body
  along the killing shot (the parent systems are not used: their `blood_impact_red_01_chunk` child
  draws as black flakes in CS:S), and `sm_blood_death_pool_decals` blood decals are laid on the floor under the
  body, one after the other, so the pool spreads.
- **No blood on blocked damage**: the effects run in `OnTakeDamage_Alive`, which only fires when
  the damage applies. Teammates with friendly fire off, or players under spawn protection from
  another plugin, do not bleed.
- **Temp entity budget**: the engine sends a limited number of temp entities per snapshot and
  drops the rest, stock impact effects included. The plugin never sends more than
  `sm_blood_max_tempents` in one server tick (a shotgun blast is up to 9 hits in the same tick).
- Particles are only sent to players who can see the spot; decals stay on the map, so they are
  sent to everyone. Decals only stick to the world, not to doors, `func_brush` or props.

The particle systems come from `particles/blood_impact.pcf` (HL2 / Episode Two), which CS:S lists
in `particles/particles_manifest.txt`, so every client already has them. They are played with the
`EffectDispatch` temp entity and the `ParticleEffect` client effect; their names are added to the
`ParticleEffectNames` string table on map start.

## Installation

Extract the release archive matching your SourceMod version (`-sm1.12` or `-sm1.13`) into `cstrike/`:

- `addons/sourcemod/plugins/Blood.smx`

The config `cfg/sourcemod/plugin.Blood.cfg` is created on first load.

## Cvars

| Cvar | Default | Description |
| - | - | - |
| `sm_blood_enable` | `1` | Enable the extra blood |
| `sm_blood_particles` | `1` | Blood particle burst on each hit |
| `sm_blood_headshot_spurt` | `1` | Extra spurt of blood droplets on headshots |
| `sm_blood_death_burst` | `1` | Large blood splash on the body when a player dies |
| `sm_blood_wall_distance` | `150` | Distance behind the victim, along the shot, where blood can splatter a wall or the floor, `0` = off |
| `sm_blood_wall_decals` | `1` | Blood decals put on the wall per hit (twice as many on headshots) |
| `sm_blood_death_pool` | `1` | Leave a pool of blood on the floor where a player dies |
| `sm_blood_death_pool_decals` | `5` | Decals that make up a death pool |
| `sm_blood_max_tempents` | `16` | Most temp entities the plugin sends per server tick |

## License

GPL-3.0, see [LICENSE](LICENSE).
