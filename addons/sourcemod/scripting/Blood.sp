#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

#define HITGROUP_HEAD 1

// Damage types that come from a bullet or a knife. The CS:S knife deals DMG_BULLET | DMG_NEVERGIB,
// DMG_SLASH and DMG_CLUB are kept for melee weapons added by other plugins.
#define DMG_HIT_MASK (DMG_BULLET | DMG_SLASH | DMG_CLUB)

// The blood decals are 128x128 textures with $decalscale 0.25, so about 32 units wide in the
// world. Pool decals are spread inside this radius so they overlap into one larger stain.
#define POOL_RADIUS 14.0
// How far below the feet of a dead player the floor is searched for the pool
#define POOL_FLOOR_SEARCH 96.0
// Delay before the first pool decal and between two of them, so the pool grows under the body
// instead of appearing at once
#define POOL_DELAY_FIRST 0.3
#define POOL_DELAY_STEP 0.15

// Random spread added to the shot direction for each extra wall decal and spray
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

// Dark red: the stock HL2 blood color, a full 255 red looks pink on the sprites
static const int g_iBloodColor[4] = { 150, 0, 0, 255 };

ConVar g_cvEnable;
ConVar g_cvAmount;
ConVar g_cvSprays;
ConVar g_cvHeadshotMult;
ConVar g_cvWallDistance;
ConVar g_cvWallDecals;
ConVar g_cvDeathPool;
ConVar g_cvDeathPoolDecals;
ConVar g_cvMaxTempEnts;

int g_iDecals[sizeof(g_sDecalNames)];
int g_iSprayModel = -1;
int g_iDropModel = -1;

// Hit group of the last TraceAttack on each player, and the tick it happened on. The damage
// position comes later in OnTakeDamage_Alive, which does not carry the hit group.
int g_iHitGroup[MAXPLAYERS + 1];
int g_iHitGroupTick[MAXPLAYERS + 1] = { -1, ... };

// Temp entities sent during the current tick
int g_iBudgetTick = -1;
int g_iBudgetUsed;

public Plugin myinfo =
{
	name = "Blood",
	author = "Rushaway",
	description = "More blood: bigger hit sprays, wall splatters and death pools",
	version = PLUGIN_VERSION,
	url = "https://github.com/srcdslab/sm-plugin-Blood"
};

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("sm_blood_enable", "1", "Enable the extra blood", _, true, 0.0, true, 1.0);
	g_cvAmount = CreateConVar("sm_blood_amount", "12", "Size of the blood spray on a hit (the stock HL2 spray goes from 3 to 16)", _, true, 1.0, true, 255.0);
	g_cvSprays = CreateConVar("sm_blood_sprays", "2", "Blood sprays per hit, 0 = no spray", _, true, 0.0, true, 8.0);
	g_cvHeadshotMult = CreateConVar("sm_blood_headshot_mult", "2.0", "Headshot multiplier for the spray size, the spray count and the wall decals", _, true, 1.0, true, 5.0);
	g_cvWallDistance = CreateConVar("sm_blood_wall_distance", "150", "Distance behind the victim, along the shot, where blood can splatter a wall or the floor, 0 = off", _, true, 0.0, true, 1000.0);
	g_cvWallDecals = CreateConVar("sm_blood_wall_decals", "1", "Blood decals put on the wall per hit", _, true, 0.0, true, 4.0);
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

	// Same sprites as the stock UTIL_BloodDrips, already precached by the game
	g_iSprayModel = PrecacheModel("sprites/bloodspray.vmt", true);
	g_iDropModel = PrecacheModel("sprites/blood.vmt", true);

	g_iBudgetTick = -1;
	g_iBudgetUsed = 0;
}

public void OnClientPutInServer(int client)
{
	g_iHitGroupTick[client] = -1;
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

	// TraceAttack runs in the same tick as the damage it belongs to: an older hit group is stale
	bool bHeadshot = g_iHitGroupTick[victim] == GetGameTickCount() && g_iHitGroup[victim] == HITGROUP_HEAD;
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
		// Fall, grenade or world damage: no hit point, bleed from the middle of the body
		float fFeet[3];
		float fEye[3];
		GetClientAbsOrigin(victim, fFeet);
		GetClientEyePosition(victim, fEye);
		AddVectors(fFeet, fEye, fHitPos);
		ScaleVector(fHitPos, 0.5);
		fDir[2] = 1.0;
	}

	if (IsZeroVector(fDir))
		fDir[2] = 1.0;
	NormalizeVector(fDir, fDir);

	float fMult = bHeadshot ? g_cvHeadshotMult.FloatValue : 1.0;

	SpawnSprays(fHitPos, fDir, fMult);

	// Wall splatter only for a bullet or knife hit from another player: self-damage, world and
	// fall damage have no meaningful shot direction
	if (bHit && bByEnemy)
		SpawnWallDecals(fHitPos, fDir, fMult);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue || !g_cvDeathPool.BoolValue)
		return;

	int iVictim = GetClientOfUserId(event.GetInt("userid"));
	if (!iVictim || !IsClientInGame(iVictim))
		return;

	float fOrigin[3];
	GetClientAbsOrigin(iVictim, fOrigin);
	SpawnDeathPool(fOrigin);
}

void SpawnSprays(const float fPos[3], const float fDir[3], float fMult)
{
	if (g_iSprayModel == -1 || g_iDropModel == -1)
		return;

	int iCount = RoundToNearest(g_cvSprays.IntValue * fMult);
	int iSize = RoundToNearest(g_cvAmount.IntValue * fMult);
	if (iSize > 255)
		iSize = 255; // m_nSize is sent on 8 bits

	for (int i = 0; i < iCount; i++)
	{
		if (!TakeBudget())
			return;

		float fSprayDir[3];
		JitterDirection(fDir, fSprayDir, i == 0 ? 0.0 : DIRECTION_JITTER);

		TE_SetupBloodSprite(fPos, fSprayDir, g_iBloodColor, iSize, g_iSprayModel, g_iDropModel);
		// A spray only lasts a moment: send it to the players who can see the spot
		TE_SendToAllInRange(fPos, RangeType_Visibility);
	}
}

void SpawnWallDecals(const float fHitPos[3], const float fDir[3], float fMult)
{
	float fDistance = g_cvWallDistance.FloatValue;
	if (fDistance <= 0.0)
		return;

	int iCount = RoundToNearest(g_cvWallDecals.IntValue * fMult);
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
