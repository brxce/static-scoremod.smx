/*
	SourcePawn is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	SourceMod is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	Pawn and SMALL are Copyright (C) 1997-2008 ITB CompuPhase.
	Source is Copyright (C) Valve Corporation.
	All trademarks are property of their respective owners.

	This program is free software: you can redistribute it and/or modify it
	under the terms of the GNU General Public License as published by the
	Free Software Foundation, either version 3 of the License, or (at your
	option) any later version.

	This program is distributed in the hope that it will be useful, but
	WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/* 
	Bibliography:
	'l4d2_scoremod' by CanadaRox, ProdigySim
	'damage_bonus' by CanadaRox, Stabby
	'l4d2_scoringwip' by ProdigySim
	'srs.scoringsystem' by AtomicStryker
	'eq2_scoremod' by Visor
*/

#pragma semicolon 1

#define SM_DEBUG 1
#define TEAM_ONE 0
#define TEAM_TWO 1

#include <sourcemod>
#include <sdkhooks>
#include <left4downtown>
#include <l4d2_direct>
#include <l4d2lib>

new const TEMP_HEALTH_MULTIPLIER 	= 1; //having a multiplier of x1 simplifies the numbers of all the types of temp health
new const STARTING_PILL_BONUS		= 50; //for survivors to lose; applies to starting four pills only
new	const PILL_CONSUMPTION_PENALTY	= 50; //fast movement is its own reward, granting bonus for scavenged pills makes for a convoluted system
new	const INCAP_HEALTH				= 30; //this for survivors to lose, and also handily accounts for the 30 temp health gained when revived
new	const INCAPS_BEFORE_DEATH		= 2;
new const MAX_HEALTH				= 100;

new bool:bInSecondHalf = true; //flipped at the start of every round i.e. at the start of the game it becomes false
new bool:bIsRoundOver;
new Float:fBonusScore[2]; //the final health bonus for the round after map multiplier has been applied
new Float:fMapBonus;
new Float:fMapDistance;
new iTeamSize;
new iPillsConsumed;

//Interaction with external input
new Handle:hCVarPermHealthMultiplier; //x1.5 by default
new Handle:hCvarSurvivalBonus; //vanilla: 25 per survivor
new Handle:hCvarTieBreaker; //used to remove tiebreaker points

/*
	HEALTH POOL: 
		+ total perm * multipler
		+ total temp * 1 
		+ 50 * Starting pills retained
		+ 30 * incaps avoided 
	MAP MULTIPLIER:
	| 2* map distance |
	    divided by
	| max health bonus |{ 4 survivors * [ (100*perm multiplier) + (2*30 incaphealth) + (50 pillhealth) ] }
	
	-> Bonus = HEALTH POOL * MAP MULTIPLIER
*/

public Plugin:myinfo = {
	name = "Newteee's Scoremod",
	author = "Newteee, Breezy",
	description = "A health bonus scoremod",
	version = "1.0",
	url = "https://github.com/breezyplease/pit-scoremod"
};

//TODO: ledge hang taking away perm health?
//set incapavoidancebonus, don't use subtraction (b/c edge case of suicide/death charges)

public OnPluginStart() {
	#if SM_DEBUG
		PrintToChatAll("OnPluginStart()");
	#endif
	//Changing console variables
	hCvarSurvivalBonus = FindConVar("vs_survival_bonus");
	hCvarTieBreaker = FindConVar("vs_tiebreak_bonus");
	
	//.cfg variable
	hCVarPermHealthMultiplier = CreateConVar("perm_health_multiplier", "1.5", "Multiplier for permanent health", FCVAR_PLUGIN);

	//Hooking game events to plugin functions
	HookEvent("versus_round_start", EventHook:OnVersusRoundStart, EventHookMode_PostNoCopy);
	HookEvent("pills_used", EventHook:OnPillsUsed, EventHookMode_PostNoCopy);
	
	//In-game "sm_/!" prefixed commands to call CmdBonus() function
	RegConsoleCmd("sm_health", CmdBonus);
	RegConsoleCmd("sm_damage", CmdBonus);
	RegConsoleCmd("sm_bonus", CmdBonus);
	//Map multiplier info, etc.
	RegConsoleCmd("sm_info", CmdInfo);
	RegConsoleCmd("sm_mapinfo", CmdMapInfo);
}

public OnConfigsExecuted() {
	SetConVarInt(hCvarTieBreaker, 0);
	iTeamSize = GetConVarInt( FindConVar("survivor_limit") );
	new iDistance = L4D2_GetMapValueInt( "max_distance", L4D_GetVersusMaxCompletionScore() );
	fMapDistance = float(iDistance);
	#if SM_DEBUG
		PrintToChatAll("OnConfigsExecuted()");
	#endif
}

public OnVersusRoundStart() {
	#if SM_DEBUG
	PrintToChatAll("OnVersusRoundStart()");
	#endif
	iPillsConsumed = 0;
	fMapBonus = CalculateBonusScore();
	bIsRoundOver = false;
	bInSecondHalf = !bInSecondHalf;
}

public OnPillsUsed() {
	iPillsConsumed++;
}

public Action:L4D2_OnEndVersusModeRound() { //bool:countSurvivors could possibly be used as a parameter here
	new team = 0;
	if (!bInSecondHalf) {
		team = TEAM_ONE;
	} else {
		team = TEAM_TWO;
	}
	fBonusScore[team] = CalculateBonusScore();
	//Check if team has wiped
	new iSurvivalMultiplier = CountUprightSurvivors();
	if (iSurvivalMultiplier == 0) { 
		PrintToChatAll("Survivors wiped out");
		return Plugin_Continue;
	} else if (fBonusScore[team] <= 0) {
		PrintToChatAll("Bonus depleted");
	}
	//Set score (L4D2 awards bonus on a per survivor basis -> divide calculated bonus by number of standing survivors)
	SetConVarInt(hCvarSurvivalBonus, RoundToFloor(fBonusScore[team]/iSurvivalMultiplier) );
	
	// Scores print
	CreateTimer(3.0, PrintRoundEndStats, _, TIMER_FLAG_NO_MAPCHANGE);
	bIsRoundOver = true;
	return Plugin_Continue;
}

public Action:PrintRoundEndStats(Handle:timer) {
	if (bInSecondHalf == false) {
		PrintToChatAll( "\x01[\x04SM\x01 :: Round \x031\x01] Bonus: \x05%i\x01/\x05%i\x01", RoundToFloor(fBonusScore[TEAM_ONE]), RoundToFloor(fMapBonus) );
		// [SM :: Round 1] Bonus: 487/1200 
	} else {
		PrintToChatAll( "\x01[\x04SM\x01 :: Round \x032\x01] Bonus: \x05%i\x01/\x05%i\x01", RoundToFloor(fBonusScore[TEAM_TWO]), RoundToFloor(fMapBonus) );
		// [SM :: Round 2] Bonus: 487/1200 
	}
}

public OnPluginEnd() {
	ResetConVar(hCvarSurvivalBonus);
	ResetConVar(hCvarTieBreaker);
}

public CvarChanged(Handle:convar, const String:oldValue[], const String:newValue[]) {
	OnConfigsExecuted(); //re-adjust if survivor_limit, perm health multiplier etc. are changed mid game
}

public Action:CmdBonus(client, args) {
	#if SM_DEBUG
		PrintToChatAll("CmdBonus()");
	#endif
	if (bIsRoundOver || !client) {
		#if SM_DEBUG
			if (bIsRoundOver) {
				PrintToChatAll("bIsRoundOver: true ");
			} else {
				PrintToChatAll("!client");
			}			
		#endif
		return Plugin_Handled;
	} else {
		new Float:fBonus = CalculateBonusScore();		
		if (!bInSecondHalf) {
			PrintToChat( client, "\x01[\x04SM\x01 :: R\x03#1\x01] Bonus: \x05%d\x01", RoundToFloor(fBonus));
			// [SM :: R#1] Bonus: 556
		} else { //Print for R#2
			PrintToChat( client, "\x01[\x04SM\x01 :: R\x03#2\x01] Bonus: \x05%d\x01", RoundToFloor(fBonus));
			// [SM :: R#2] Bonus: 556
		}	
		return Plugin_Continue;
	}	
}

public Action:CmdInfo(client, args) {
	PrintToChat(client, "\x01[\x04Health bonus pool - breakdown]");
	PrintToChat(client, "\x05Permanent health -> (x1.5 default multiplier)");
	PrintToChat(client, "\x01- Held perm health:		100");
	PrintToChat(client, "\x05Temporary health -> (x1.0 multiplier)");
	PrintToChat(client, "\x01- Held temp health:		__");
	PrintToChat(client, "\x01- Starting pill bonus:		50");
	PrintToChat(client, "\x01- Incap Avoidance bonus: 	30 per incap avoided (2 max incaps per survivor)");
	PrintToChat(client, "\x05Each survivor contributes 100*1.5 + 50 + 60 = 260 bonus");
	PrintToChat(client, "\x05 -> total 4v4 starting bonus of 4x260 = 1040 (before map multiplier)");
	PrintToChat(client, "");
	return Plugin_Handled;
}

public Action:CmdMapInfo(client, args) {
	PrintToChat(client, "\x01[\x04SM\x01 :: \x03%iv%i\x01] Map Info", iTeamSize, iTeamSize); // [SM :: 4v4] Map Info
	PrintToChat(client, "\x01Map Distance: \x05%f\x01", fMapDistance);
	PrintToChat(client, "\x01Map Multiplier: \x05%f\x01", GetMapMultiplier()); // Map multiplier
	PrintToChat(client, "");
	return Plugin_Handled;
}

CountUprightSurvivors() {
	new iUprightCount = 0;
	new iSurvivorCount = 0;
	for (new i = 1; i <= MaxClients && iSurvivorCount < iTeamSize; i++)
	{
		if (IsSurvivor(i))
		{
			iSurvivorCount++;
			if (IsPlayerAlive(i) && !IsPlayerIncap(i) && !IsPlayerLedged(i))
			{
				iUprightCount++;
			}
		}
	}
	#if SM_DEBUG
		PrintToChatAll("CountUprightSurvivors()");
		PrintToChatAll("- iUprightCount: %i", iUprightCount);
	#endif
	return iUprightCount;
}

bool:IsSurvivor(client) {
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2;
}

bool:IsPlayerIncap(client) {
	return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated");
}

bool:IsPlayerLedged(client)
{
	return bool:(GetEntProp(client, Prop_Send, "m_isHangingFromLedge") | GetEntProp(client, Prop_Send, "m_isFallingFromLedge"));
}

Float:CalculateBonusScore() {// Apply map multiplier to the sum of the permanent and temporary health bonuses
	#if SM_DEBUG
		PrintToChatAll("\x04CalculateBonusScore()");
		PrintToChatAll(" ");
	#endif
	new Float:fPermBonus = GetPermBonus();
	new Float:fTempBonus = GetTempBonus();
	new Float:fMapMultiplier = GetMapMultiplier();
	new Float:fHealth = fPermBonus + fTempBonus;
	new Float:fHealthBonus = fHealth * fMapMultiplier;
	#if SM_DEBUG
		PrintToChatAll("\x04-> Total health pool: \x05%f", fHealth);
		PrintToChatAll("\x04-> fMapMultiplier: \x05%f", fMapMultiplier);
		PrintToChatAll("\x04-> fHealthBonus: \x05%f", fHealthBonus);
	#endif
	return fHealthBonus;
}

// Permanent health held * multiplier (1.5 by default)
Float:GetPermBonus() { 
	new iPermHealth = 0;
	#if SM_DEBUG
		PrintToChatAll("GetPermBonus()");
		PrintToChatAll( "hCVarPermHealthMultiplier: \x05%f", GetConVarFloat(hCVarPermHealthMultiplier) );
	#endif
	for (new index = 1; index < MaxClients; index++)
	{
		//Add permanent health held by each non-incapped survivor
		if (IsSurvivor(index) && !IsPlayerIncap(index)) { 
			if (GetEntProp(index, Prop_Send, "m_currentReviveCount") == 0 ) { //
				if (GetEntProp(index, Prop_Send, "m_iHealth") > 0) {
					iPermHealth += GetEntProp(index, Prop_Send, "m_iHealth");
					#if SM_DEBUG
						PrintToChatAll("- Found a survivor with \x05%d perm health", GetEntProp(index, Prop_Send, "m_iHealth"));
					#endif
				} 
			}
		}
	}		
	new Float:fPermHealthBonus = iPermHealth * GetConVarFloat(hCVarPermHealthMultiplier);
	#if SM_DEBUG
		PrintToChatAll("\x04fPermHealthBonus: \x05%f", fPermHealthBonus);
	#endif
	return (fPermHealthBonus > 0 ? fPermHealthBonus: 0.0);
}

/*
Start with temp health held by survivors
Temp bonus is the same as temp health because of the x1 TEMP_HEALTH_MULTIPLIER
- subtract an 'incap penalty' to neutralise temp bonus gained when picked up  
- subtract a 'scavenged pills penalty' to neutralise temp bonus gained from non-starting pills
*/
Float:GetTempBonus() { 
	#if SM_DEBUG
		PrintToChatAll("GetTempBonus()");
	#endif
	new iTempHealthPool = 0; //the team's collective temp health pool
	new iIncapsSuffered = 0; 
	for (new index = 1; index < MaxClients; index++) {
		if (IsSurvivor(index) && !IsPlayerIncap(index)) { //incapped survivors are granted 300 temp health until revival			
			if (IsPlayerAlive(index)) { //count incaps, add temp health to pool
				iIncapsSuffered += GetEntProp(index, Prop_Send, "m_currentReviveCount"); 
				new iThisSurvivorTempHealth = RoundToCeil(GetEntPropFloat(index, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(index, Prop_Send, "m_healthBufferTime")) * GetConVarFloat(FindConVar("pain_pills_decay_rate")))) - 1;
				if (iThisSurvivorTempHealth > 0) {
					//Add temp health held by each survivor
					iTempHealthPool += iThisSurvivorTempHealth;
					#if SM_DEBUG
						PrintToChatAll("- Found a survivor with \x05%i temp health", iThisSurvivorTempHealth);
					#endif				
				} else {
					#if SM_DEBUG
						PrintToChatAll("- Found a survivor with no temp health");
					#endif
				}			
			} else { //dead survivor, penalise for 2 incaps
				iIncapsSuffered += INCAPS_BEFORE_DEATH;
				#if SM_DEBUG
					PrintToChatAll("- Found a dead survivor");
				#endif
			}			
		}
	}	
	#if SM_DEBUG
		PrintToChatAll("\x04Total temp health held by survivors: \x05%i", iTempHealthPool);
	#endif
	new iStartingPillBonus = STARTING_PILL_BONUS * iTeamSize;
	new iPillConsumptionPenalty = iPillsConsumed * PILL_CONSUMPTION_PENALTY;
	new iIncapsAvoided = (INCAPS_BEFORE_DEATH * iTeamSize) - iIncapsSuffered;
	new iIncapAvoidanceBonus = iIncapsAvoided * INCAP_HEALTH;
	iTempHealthPool += iStartingPillBonus;
	iTempHealthPool += iIncapAvoidanceBonus;
	iTempHealthPool -= iPillConsumptionPenalty;
	new Float:fTempHealthBonus = float(iTempHealthPool * TEMP_HEALTH_MULTIPLIER); // x1
	#if SM_DEBUG
		PrintToChatAll("- iStartingPillBonus: \x05%i", iStartingPillBonus);
		PrintToChatAll("- iIncapAvoidanceBonus: \x05%i", iIncapAvoidanceBonus);
		PrintToChatAll("- iPillConsumptionPenalty: \x05%i", iPillConsumptionPenalty);
		PrintToChatAll("\x04fTempHealthBonus: \x05%f", fTempHealthBonus);
	#endif
	return (fTempHealthBonus > 0 ? fTempHealthBonus : 0.0);
}

Float:GetMapMultiplier() { // (2 * Map Distance)/Max health bonus (1040 by default w/ 1.5 perm health multiplier)
	new Float:fMaxPermBonus = MAX_HEALTH * GetConVarFloat(hCVarPermHealthMultiplier);
	new iSurvivorIncapHealth = INCAP_HEALTH * INCAPS_BEFORE_DEATH;
	new Float:fMapMultiplier = ( 2 * fMapDistance )/( iTeamSize*(fMaxPermBonus + STARTING_PILL_BONUS + iSurvivorIncapHealth));
	#if SM_DEBUG
		PrintToChatAll("GetMapMultiplier()");
	#endif
	return fMapMultiplier;
}
	