# Blood

SourceMod plugin for Counter-Strike: Source that adds more blood: bigger sprays on hits, blood
splattered on the walls behind the victim and a pool of blood where a player dies.

Written for 64-bit CS:S servers: pure SourcePawn, no extension, no gamedata of its own. It uses
SDKHooks (`TraceAttack`, `OnTakeDamage_Alive`), whose offsets ship with SourceMod for `linux` and
`linux64`, and stock temp entities. Clients download nothing: every sprite and decal comes with
the game.

## How it works

- **Hit spray**: each hit draws `sm_blood_sprays` blood sprays of size `sm_blood_amount` at the
  hit point, thrown along the shot direction (`Blood Sprite` temp entity with
  `sprites/bloodspray.vmt` and `sprites/blood.vmt`). Hits without a hit point (fall damage,
  grenades, world damage) bleed from the middle of the body.
- **Wall splatter**: for a bullet or knife hit from another player, the plugin traces from the hit
  point along the shot, from the attacker's eyes through the victim, for `sm_blood_wall_distance`
  units. If it reaches a world surface (wall or floor), it puts `sm_blood_wall_decals` blood decals
  there (`World Decal` temp entity with a random `decals/blood1` to `decals/blood6`). Self-damage,
  world and fall damage never splatter walls.
- **Headshots**: the spray size, the spray count and the wall decal count are multiplied by
  `sm_blood_headshot_mult`.
- **Death pool**: when a player dies, `sm_blood_death_pool_decals` blood decals are laid on the
  floor under the body, one after the other, so the pool spreads.
- **No blood on blocked damage**: the effects run in `OnTakeDamage_Alive`, which only fires when
  the damage applies. Teammates with friendly fire off, or players under spawn protection from
  another plugin, do not bleed.
- **Temp entity budget**: the engine sends a limited number of temp entities per snapshot and
  drops the rest, stock impact effects included. The plugin never sends more than
  `sm_blood_max_tempents` in one server tick (a shotgun blast is up to 9 hits in the same tick).
- Sprays are only sent to players who can see the spot; decals stay on the map, so they are sent
  to everyone. Decals only stick to the world, not to doors, `func_brush` or props.

## Installation

Extract the release archive matching your SourceMod version (`-sm1.12` or `-sm1.13`) into `cstrike/`:

- `addons/sourcemod/plugins/Blood.smx`

The config `cfg/sourcemod/plugin.Blood.cfg` is created on first load.

## Cvars

| Cvar | Default | Description |
| - | - | - |
| `sm_blood_enable` | `1` | Enable the extra blood |
| `sm_blood_amount` | `12` | Size of the blood spray on a hit (`1`-`255`, the stock HL2 spray goes from 3 to 16) |
| `sm_blood_sprays` | `2` | Blood sprays per hit, `0` = no spray |
| `sm_blood_headshot_mult` | `2.0` | Headshot multiplier for the spray size, the spray count and the wall decals |
| `sm_blood_wall_distance` | `150` | Distance behind the victim, along the shot, where blood can splatter a wall or the floor, `0` = off |
| `sm_blood_wall_decals` | `1` | Blood decals put on the wall per hit |
| `sm_blood_death_pool` | `1` | Leave a pool of blood on the floor where a player dies |
| `sm_blood_death_pool_decals` | `5` | Decals that make up a death pool |
| `sm_blood_max_tempents` | `16` | Most temp entities the plugin sends per server tick |

## License

GPL-3.0, see [LICENSE](LICENSE).
