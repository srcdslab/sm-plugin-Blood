#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.1"

#define HITGROUP_HEAD 1

// Damage types that come from a bullet or a knife. The CS:S knife deals DMG_BULLET | DMG_NEVERGIB,
// DMG_SLASH and DMG_CLUB are kept for melee weapons added by other plugins.
#define DMG_HIT_MASK (DMG_BULLET | DMG_SLASH | DMG_CLUB)

// Particle systems from particles/blood_impact.pcf (cstrike_pak_dir.vpk). The file is listed in
// particles/particles_manifest.txt, so every CS:S client loads it at startup; CS:S itself never
// uses it (its stock blood is the "csblood" effect), the systems come from HL2 / EP2.
// Each one sprays along +X of the orientation it is given (its "Position Within Sphere Random"
// initializer has a local speed of +X 10..90 for the impact, +X 48..50 for the spray,
// +X 35..50 for the puncture), so they are dispatched with the angles of the shot direction:
// the blood leaves the victim on the far side, away from the shooter.
// The parent systems (blood_impact_red_01, blood_advisor_puncture) also spawn
// blood_impact_red_01_chunk, which draws as black flakes in CS:S (seen in game on 2026-11-23):
// their children are dispatched one by one instead, without the chunks.
// Hit: red mist, a goop splash and small droplets (blood_impact_red_01 minus its chunks)
char g_sParticlesHit[][] = { "blood_impact_red_01_mist", "blood_impact_red_01_goop", "blood_impact_red_01_smalldroplets" };
// Headshot: an extra burst of bright red droplets and a goop splash, on top of the hit particles.
// blood_advisor_shrapnel_spray_1 used before is the Advisor's yellow-green blood (159, 158, 34):
// players saw it as vomit. blood_advisor_pierce_spray is red but so dark (27..66) that it drew
// as a grey-black cloud against the sky (both seen in game on 2026-11-23).
char g_sParticlesHeadshot[][] = { "blood_impact_red_01_droplets", "blood_impact_red_01_goop", "blood_impact_red_01_droplets" };
// Death: two goop splashes, mist and droplets (blood_advisor_puncture minus its chunks)
char g_sParticlesDeath[][] = { "blood_impact_red_01_goop", "blood_impact_red_01_goop", "blood_impact_red_01_mist", "blood_impact_red_01_droplets" };

// Headshots put twice as many decals on the wall behind the victim
#define HEADSHOT_WALL_DECAL_MULT 2

// The blood decals are 128x128 textures with $decalscale 0.25, so about 32 units wide in the
// world. Pool decals are spread inside this radius so they overlap into one larger stain.
#define POOL_RADIUS 14.0
// How far below the feet of a dead player the floor is searched for the pool
#define POOL_FLOOR_SEARCH 96.0
// Delay before the first pool decal and between two of them, so the pool grows under the body
// instead of appearing at once
#define POOL_DELAY_FIRST 0.3
#define POOL_DELAY_STEP 0.15

// Random spread added to the shot direction for each extra wall decal
#define DIRECTION_JITTER 0.12

// Stock HL2 blood decal materials, shipped with every Source game (hl2_misc_dir.vpk). The game
// itself precaches them for model decals (scripts/decals_subrect.txt, "Models" section), so
// PrecacheDecal only returns their index. They are standalone materials: unlike the
// decals/bloodN_subrect variants the game uses on brushes, they do not point into a decal atlas.
static const char g_sDecalNames[][] =
{
	"decals/blood1",
	"decals/blood2",
	"decals/blood3",
	"decals/blood4",
	"decals/blood5",
	"decals/blood6"
};

ConVar g_cvEnable;
ConVar g_cvParticles;
ConVar g_cvHeadshotSpurt;
ConVar g_cvDeathBurst;
ConVar g_cvWallDistance;
ConVar g_cvWallDecals;
ConVar g_cvDeathPool;
ConVar g_cvDeathPoolDecals;
ConVar g_cvMaxTempEnts;

int g_iDecals[sizeof(g_sDecalNames)];

// Index of the "ParticleEffect" client effect in the "EffectDispatch" string table, and of each
// particle system in the "ParticleEffectNames" string table
int g_iEffectParticle = INVALID_STRING_INDEX;
int g_iParticlesHit[sizeof(g_sParticlesHit)];
int g_iParticlesHeadshot[sizeof(g_sParticlesHeadshot)];
int g_iParticlesDeath[sizeof(g_sParticlesDeath)];

// Hit group of the last TraceAttack on each player, and the tick it happened on. The damage
// position comes later in OnTakeDamage_Alive, which does not carry the hit group.
int g_iHitGroup[MAXPLAYERS + 1];
int g_iHitGroupTick[MAXPLAYERS + 1] = { -1, ... };

// Direction of the last hit on each player and its tick: player_death fires during the killing
// hit, so the death burst can follow the killing shot
float g_fLastHitDir[MAXPLAYERS + 1][3];
int g_iLastHitTick[MAXPLAYERS + 1] = { -1, ... };

// Temp entities sent during the current tick
int g_iBudgetTick = -1;
int g_iBudgetUsed;

public Plugin myinfo =
{
	name = "Blood",
	author = "Rushaway",
	description = "More blood: blood particles on hits, wall splatters and death pools",
	version = PLUGIN_VERSION,
	url = "https://github.com/srcdslab/sm-plugin-Blood"
};

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("sm_blood_enable", "1", "Enable the extra blood", _, true, 0.0, true, 1.0);
	g_cvParticles = CreateConVar("sm_blood_particles", "1", "Blood particle burst on each hit", _, true, 0.0, true, 1.0);
	g_cvHeadshotSpurt = CreateConVar("sm_blood_headshot_spurt", "1", "Extra spurt of blood droplets on headshots", _, true, 0.0, true, 1.0);
	g_cvDeathBurst = CreateConVar("sm_blood_death_burst", "1", "Large blood splash on the body when a player dies", _, true, 0.0, true, 1.0);
	g_cvWallDistance = CreateConVar("sm_blood_wall_distance", "150", "Distance behind the victim, along the shot, where blood can splatter a wall or the floor, 0 = off", _, true, 0.0, true, 1000.0);
	g_cvWallDecals = CreateConVar("sm_blood_wall_decals", "1", "Blood decals put on the wall per hit (twice as many on headshots)", _, true, 0.0, true, 4.0);
	g_cvDeathPool = CreateConVar("sm_blood_death_pool", "1", "Leave a pool of blood on the floor where a player dies", _, true, 0.0, true, 1.0);
	g_cvDeathPoolDecals = CreateConVar("sm_blood_death_pool_decals", "5", "Decals that make up a death pool", _, true, 1.0, true, 10.0);
	g_cvMaxTempEnts = CreateConVar("sm_blood_max_tempents", "16", "Most temp entities this plugin sends per server tick (shotgun pellets and several kills in one tick can add up)", _, true, 1.0, true, 64.0);

	AutoExecConfig(true);

	HookEvent("player_death", Event_PlayerDeath);

	// Late load: hook the players already on the server
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (IsClientInGame(iClient))
			OnClientPutInServer(iClient);
	}
}

public void OnMapStart()
{
	for (int i = 0; i < sizeof(g_sDecalNames); i++)
		g_iDecals[i] = PrecacheDecal(g_sDecalNames[i], true);

	g_iEffectParticle = GetOrAddStringIndex("EffectDispatch", "ParticleEffect");
	for (int i = 0; i < sizeof(g_sParticlesHit); i++)
		g_iParticlesHit[i] = GetOrAddStringIndex("ParticleEffectNames", g_sParticlesHit[i]);
	for (int i = 0; i < sizeof(g_sParticlesHeadshot); i++)
		g_iParticlesHeadshot[i] = GetOrAddStringIndex("ParticleEffectNames", g_sParticlesHeadshot[i]);
	for (int i = 0; i < sizeof(g_sParticlesDeath); i++)
		g_iParticlesDeath[i] = GetOrAddStringIndex("ParticleEffectNames", g_sParticlesDeath[i]);

	g_iBudgetTick = -1;
	g_iBudgetUsed = 0;
}

public void OnClientPutInServer(int client)
{
	g_iHitGroupTick[client] = -1;
	g_iLastHitTick[client] = -1;
	SDKHook(client, SDKHook_TraceAttack, Hook_TraceAttack);
	// OnTakeDamage_Alive only runs when the damage really applies: no blood when friendly fire is
	// off, or when another plugin blocks the damage in OnTakeDamage (spawn protection)
	SDKHook(client, SDKHook_OnTakeDamageAlivePost, Hook_OnTakeDamageAlivePost);
}

public Action Hook_TraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
	g_iHitGroup[victim] = hitgroup;
	g_iHitGroupTick[victim] = GetGameTickCount();
	return Plugin_Continue;
}

public void Hook_OnTakeDamageAlivePost(int victim, int attacker, int inflictor, float damage, int damagetype, int weapon, const float damageForce[3], const float damagePosition[3])
{
	if (!g_cvEnable.BoolValue || damage <= 0.0)
		return;

	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
		return;

	int iTick = GetGameTickCount();

	// TraceAttack runs in the same tick as the damage it belongs to: an older hit group is stale
	bool bHeadshot = g_iHitGroupTick[victim] == iTick && g_iHitGroup[victim] == HITGROUP_HEAD;
	g_iHitGroupTick[victim] = -1;

	bool bHit = (damagetype & DMG_HIT_MASK) != 0 && !IsZeroVector(damagePosition);
	bool bByEnemy = attacker >= 1 && attacker <= MaxClients && attacker != victim && IsClientInGame(attacker);

	float fHitPos[3];
	float fDir[3];
	if (bHit)
	{
		fHitPos = damagePosition;
		if (bByEnemy)
		{
			// Shot direction: from the attacker's eyes through the hit point
			float fEye[3];
			GetClientEyePosition(attacker, fEye);
			SubtractVectors(fHitPos, fEye, fDir);
		}
		else
		{
			fDir = damageForce;
		}
	}
	else
	{
		// Fall, grenade or world damage: no hit point, bleed upwards from the middle of the body
		GetBodyCenter(victim, fHitPos);
		fDir[2] = 1.0;
	}

	if (IsZeroVector(fDir))
		fDir[2] = 1.0;
	NormalizeVector(fDir, fDir);

	g_fLastHitDir[victim] = fDir;
	g_iLastHitTick[victim] = iTick;

	if (g_cvParticles.BoolValue)
	{
		for (int i = 0; i < sizeof(g_iParticlesHit); i++)
			DispatchParticle(g_iParticlesHit[i], fHitPos, fDir);
	}

	if (bHeadshot && g_cvHeadshotSpurt.BoolValue)
	{
		for (int i = 0; i < sizeof(g_iParticlesHeadshot); i++)
			DispatchParticle(g_iParticlesHeadshot[i], fHitPos, fDir);
	}

	// Wall splatter only for a bullet or knife hit from another player: self-damage, world and
	// fall damage have no meaningful shot direction
	if (bHit && bByEnemy)
		SpawnWallDecals(fHitPos, fDir, bHeadshot ? HEADSHOT_WALL_DECAL_MULT : 1);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
		return;

	int iVictim = GetClientOfUserId(event.GetInt("userid"));
	if (!iVictim || !IsClientInGame(iVictim))
		return;

	if (g_cvDeathBurst.BoolValue)
	{
		float fCenter[3];
		GetBodyCenter(iVictim, fCenter);

		// Follow the killing hit; without one (suicide, trigger_hurt...) splash upwards
		float fDir[3];
		if (g_iLastHitTick[iVictim] == GetGameTickCount())
			fDir = g_fLastHitDir[iVictim];
		else
			fDir[2] = 1.0;

		for (int i = 0; i < sizeof(g_iParticlesDeath); i++)
			DispatchParticle(g_iParticlesDeath[i], fCenter, fDir);
	}

	if (g_cvDeathPool.BoolValue)
	{
		float fOrigin[3];
		GetClientAbsOrigin(iVictim, fOrigin);
		SpawnDeathPool(fOrigin);
	}
}

void SpawnWallDecals(const float fHitPos[3], const float fDir[3], int iMult)
{
	float fDistance = g_cvWallDistance.FloatValue;
	if (fDistance <= 0.0)
		return;

	int iCount = g_cvWallDecals.IntValue * iMult;
	for (int i = 0; i < iCount; i++)
	{
		float fTraceDir[3];
		JitterDirection(fDir, fTraceDir, i == 0 ? 0.0 : DIRECTION_JITTER);

		float fEnd[3];
		fEnd = fTraceDir;
		ScaleVector(fEnd, fDistance);
		AddVectors(fHitPos, fEnd, fEnd);

		float fWallPos[3];
		if (TraceToWorld(fHitPos, fEnd, fWallPos))
			SendWorldDecal(fWallPos, 0.0);
	}
}

void SpawnDeathPool(const float fOrigin[3])
{
	// Find the floor under the body. Start a bit above the origin: on a slope or a step the
	// origin can sit slightly inside the ground.
	float fStart[3];
	float fEnd[3];
	fStart = fOrigin;
	fStart[2] += 8.0;
	fEnd = fOrigin;
	fEnd[2] -= POOL_FLOOR_SEARCH;

	float fFloor[3];
	if (!TraceToWorld(fStart, fEnd, fFloor))
		return;

	int iCount = g_cvDeathPoolDecals.IntValue;
	for (int i = 0; i < iCount; i++)
	{
		// First decal right under the body, the others around it
		float fSpot[3];
		fSpot = fFloor;
		if (i > 0)
		{
			float fAngle = GetRandomFloat(0.0, 2.0 * FLOAT_PI);
			float fRadius = GetRandomFloat(POOL_RADIUS * 0.4, POOL_RADIUS);
			fSpot[0] += Cosine(fAngle) * fRadius;
			fSpot[1] += Sine(fAngle) * fRadius;
		}

		// Each spot gets its own short trace: a decal only sticks to a surface close to its
		// origin, so a spot past a ledge would be lost
		fStart = fSpot;
		fStart[2] += 8.0;
		fEnd = fSpot;
		fEnd[2] -= 16.0;

		float fPos[3];
		if (TraceToWorld(fStart, fEnd, fPos))
			SendWorldDecal(fPos, POOL_DELAY_FIRST + i * POOL_DELAY_STEP);
	}
}

// Traces against the world brushes only (players and props are ignored). Returns true and the
// impact point when a world surface that can take a decal was hit.
bool TraceToWorld(const float fStart[3], const float fEnd[3], float fHit[3])
{
	Handle hTrace = TR_TraceRayEx(fStart, fEnd, MASK_SOLID_BRUSHONLY, RayType_EndPoint);

	bool bHit = TR_DidHit(hTrace) && !TR_StartSolid(hTrace)
		// "World Decal" only decals entity 0: skip doors, func_brush and other brush entities
		&& TR_GetEntityIndex(hTrace) == 0
		&& (TR_GetSurfaceFlags(hTrace) & SURF_SKY) == 0;

	if (bHit)
		TR_GetEndPosition(fHit, hTrace);

	delete hTrace;
	return bHit;
}

void SendWorldDecal(const float fPos[3], float fDelay)
{
	if (!TakeBudget())
		return;

	// SourceMod has no stock for the "World Decal" temp entity. Its only fields are the position
	// and the decal precache index; the client projects the decal on the world surface at that
	// position (C_TEWorldDecal -> DecalShoot on the world model).
	TE_Start("World Decal");
	TE_WriteVector("m_vecOrigin", fPos);
	TE_WriteNum("m_nIndex", g_iDecals[GetRandomInt(0, sizeof(g_iDecals) - 1)]);
	// Decals stay on the wall: send them to everyone so the map looks the same for all players
	TE_SendToAll(fDelay);
}

// Plays a particle system at a point through the "ParticleEffect" client effect. The client
// (ParticleEffectCallback) reads the system from m_nHitBox, puts control point 0 at m_vOrigin,
// control point 1 at m_vStart and orients control point 0 with m_vAngles.
void DispatchParticle(int iParticle, const float fPos[3], const float fDir[3])
{
	if (g_iEffectParticle == INVALID_STRING_INDEX || iParticle == INVALID_STRING_INDEX)
		return;

	if (!TakeBudget())
		return;

	float fAngles[3];
	GetVectorAngles(fDir, fAngles);

	// CEffectData property names of the Orange Box engine (CS:S): the origin and start vectors are
	// sent as three floats each, "m_vOrigin[0]".."[2]" (CS:GO renamed them "m_vOrigin.x").
	// The temp entity object is shared with the game's own effects, so every field the client
	// reads for this effect is written, m_fFlags included (0 = not attached to an entity).
	TE_Start("EffectDispatch");
	TE_WriteFloat("m_vOrigin[0]", fPos[0]);
	TE_WriteFloat("m_vOrigin[1]", fPos[1]);
	TE_WriteFloat("m_vOrigin[2]", fPos[2]);
	TE_WriteFloat("m_vStart[0]", fPos[0]);
	TE_WriteFloat("m_vStart[1]", fPos[1]);
	TE_WriteFloat("m_vStart[2]", fPos[2]);
	TE_WriteVector("m_vAngles", fAngles);
	TE_WriteNum("m_fFlags", 0);
	TE_WriteNum("m_nHitBox", iParticle);
	TE_WriteNum("m_iEffectName", g_iEffectParticle);
	// Particles only last a moment: send them to the players who can see the spot
	TE_SendToAllInRange(fPos, RangeType_Visibility);
}

// SourceMod has no native to precache a particle system: add its name to the string table the
// client resolves m_nHitBox against. Done in OnMapStart, long before the first dispatch, so the
// table update reaches every client before the effect does.
int GetOrAddStringIndex(const char[] sTable, const char[] sName)
{
	int iTable = FindStringTable(sTable);
	if (iTable == INVALID_STRING_TABLE)
	{
		LogError("String table \"%s\" not found, \"%s\" disabled", sTable, sName);
		return INVALID_STRING_INDEX;
	}

	int iIndex = FindStringIndex(iTable, sName);
	if (iIndex == INVALID_STRING_INDEX)
	{
		bool bLocked = LockStringTables(false);
		AddToStringTable(iTable, sName);
		LockStringTables(bLocked);
		iIndex = FindStringIndex(iTable, sName);
	}

	return iIndex;
}

// The engine only sends a limited number of temp entities per snapshot and drops the rest,
// including the stock impact effects. Cap what this plugin adds in a single tick.
bool TakeBudget()
{
	int iTick = GetGameTickCount();
	if (iTick != g_iBudgetTick)
	{
		g_iBudgetTick = iTick;
		g_iBudgetUsed = 0;
	}

	if (g_iBudgetUsed >= g_cvMaxTempEnts.IntValue)
		return false;

	g_iBudgetUsed++;
	return true;
}

void GetBodyCenter(int client, float fCenter[3])
{
	float fFeet[3];
	float fEye[3];
	GetClientAbsOrigin(client, fFeet);
	GetClientEyePosition(client, fEye);
	AddVectors(fFeet, fEye, fCenter);
	ScaleVector(fCenter, 0.5);
}

void JitterDirection(const float fDir[3], float fOut[3], float fJitter)
{
	fOut = fDir;
	if (fJitter <= 0.0)
		return;

	for (int i = 0; i < 3; i++)
		fOut[i] += GetRandomFloat(-fJitter, fJitter);

	NormalizeVector(fOut, fOut);
}

bool IsZeroVector(const float fVec[3])
{
	return fVec[0] == 0.0 && fVec[1] == 0.0 && fVec[2] == 0.0;
}
