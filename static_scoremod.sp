/******************************************** 
	Bibliography:
	'l4d2_scoremod' by CanadaRox, ProdigySim
	'damage_bonus' by CanadaRox, Stabby
	'l4d2_scoringwip' by ProdigySim
	'srs.scoringsystem' by AtomicStryker
	'eq2_scoremod' by Visor
	'current' by CanadaRox
********************************************/

/*****************************************************************************************************************************************
	HEALTH POOL: 
		+ total perm * multipler (default 1.5)
		+ total temp * 1 
		+ 50 * Starting pills retained
		+ 30 * incaps avoided 
	MAP MULTIPLIER:
	| 2 * map distance |
	    divided by
	| max health bonus | = { number survivors * [ (100permhealth * multiplier) + (2 incaps/survivor *30 incaphealth) + (50 pillhealth) ] }
	
	-> Bonus = HEALTH POOL * MAP MULTIPLIER
*****************************************************************************************************************************************/

#pragma semicolon 1

#define SM_DEBUG 0
#define TEAM_ONE 0
#define TEAM_TWO 1

#include <sourcemod>
#include <sdkhooks>
#include <left4downtown>
#include <l4d2_direct>
#include <l4d2lib>
#define L4D2UTIL_STOCKS_ONLY
#include <l4d2util>

//had to use constants for these because sourcepawn won't let you multiply by #defined numbers
new const TEMP_HEALTH_MULTIPLIER 	= 1; //having a multiplier of x1 simplifies the numbers of all the types of temp health
new const STARTING_PILL_BONUS		= 50; //for survivors to lose; applies to starting four pills only
new	const PILL_CONSUMPTION_PENALTY	= 50; //fast movement is its own reward, granting bonus for scavenged pills makes for a convoluted system
new	const INCAP_HEALTH				= 30; //this for survivors to lose, and also handily accounts for the 30 temp health gained when revived
new	const INCAPS_BEFORE_DEATH		= 2;
new const MAX_HEALTH				= 100;

new bool:bInSecondHalf = false; 
new bool:bIsRoundOver;
new bool:bInVersusMode = false;
new Float:fBonusScore[2]; //the final health bonus for the round after map multiplier has been applied
new Float:fMaxBonusForMap;
new iMapDistance;
new iTeamSize;
new iPillsConsumed;
//For coop
new iDeadSurvivorDistPoints = 0;
new iTeamDistancePoints = 0;
new iCampaignScore = 0;

//Interaction with .cfgs
new Handle:hCVarPermHealthMultiplier; //x1.5 by default
new Handle:hCvarSurvivalBonus; //vanilla: 25 per survivor
new Handle:hCvarTieBreaker; //used to remove tiebreaker points

public Plugin:myinfo = {
	name = "Static Scoremod",
	author = "Newteee, Breezy",
	description = "A health bonus scoremod",
	version = "1.0",
	url = "https://github.com/breezyplease/static-scoremod"
};

public OnPluginStart() {
	//Changing console variables
	hCvarSurvivalBonus = FindConVar("vs_survival_bonus");
	hCvarTieBreaker = FindConVar("vs_tiebreak_bonus");
	SetConVarInt(hCvarTieBreaker, 0);	
	
	//.cfg variable
	hCVarPermHealthMultiplier = CreateConVar("perm_health_multiplier", "1.5", "Multiplier for permanent health", FCVAR_PLUGIN);
	HookConVarChange(hCVarPermHealthMultiplier, CvarChanged);
	
	//Hooking game events to plugin functions
	HookEvent("round_start", EventHook:OnRoundStart, EventHookMode_PostNoCopy); 
	HookEvent("pills_used", EventHook:OnPillsUsed, EventHookMode_PostNoCopy);
	//for coop
	HookEvent("map_transition", OnMapTransition, EventHookMode_Pre); 
	HookEvent("mission_lost", EventHook:OnMissionLost, EventHookMode_Pre);
	HookEvent("finale_win", EventHook:OnFinaleFinish, EventHookMode_PostNoCopy); //when map_transition cannot be used	
	HookEvent("player_death", OnPlayerDeath, EventHookMode_Pre); // retrieve distance points before players die
	HookEvent("round_freeze_end", EventHook:OnRoundFreezeEnd, EventHookMode_PostNoCopy); // reset coop round stats
	
	//In-game "sm_/!" prefixed commands to call CmdBonus() function
	RegConsoleCmd("sm_score", CmdScore);
	RegConsoleCmd("sm_health", CmdScore);
	RegConsoleCmd("sm_bonus", CmdScore);
	//Map multiplier info, etc.
	RegConsoleCmd("sm_scoring", CmdScoring);
	RegConsoleCmd("sm_mapinfo", CmdMapInfo);
	//Coop only
	RegConsoleCmd("sm_setscore", CmdSetScore); 
}

public OnConfigsExecuted() {	
	//Get game information
	iTeamSize = GetConVarInt( FindConVar("survivor_limit") );
	iMapDistance = L4D2_GetMapValueInt( "max_distance", L4D_GetVersusMaxCompletionScore() );
	//Calculate max bonus for map
	new Float:fPermMax = iTeamSize * MAX_HEALTH * GetConVarFloat(hCVarPermHealthMultiplier);
	new iTempMax = iTeamSize * (STARTING_PILL_BONUS + INCAPS_BEFORE_DEATH*INCAP_HEALTH); //Starting Pill & Incap Avoidance bonuses 
	new Float:fMapMulti = GetMapMultiplier();
	fMaxBonusForMap = fMapMulti * (fPermMax + iTempMax);
}

/*************************************************************************************************************
										
										FOR ALL GAME MODES
										
*************************************************************************************************************/

public OnRoundStart() {
	if (!bInVersusMode) {
		CreateTimer(5.0, Timer_PostRoundStart, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	CheckGameMode(); //gamemode is assumed to be non-versus; checks otherwise
	bInSecondHalf = bool:GameRules_GetProp("m_bInSecondHalfOfRound"); //of a versus map
	iTeamDistancePoints = 0; // for coop
	iPillsConsumed = 0;
	bIsRoundOver = false;
}

public Action:Timer_PostRoundStart(Handle:timer) {
	// Set campaign score
	//SetConVarInt(hCvarTieBreaker, iCampaignScore);
	
}

public Action:L4D_OnFirstSurvivorLeftSafeArea(client) {
	// Print scoremod information
	PrintToChatAll("\x04Type \x03!scoring \x04for scoremod info, \x03!setscore \x04to manually adjust the score");
}

public OnPillsUsed() {
	iPillsConsumed++;
}

public OnPluginEnd() {
	ResetConVar(hCvarSurvivalBonus);
	ResetConVar(hCvarTieBreaker);
}

public CvarChanged(Handle:convar, const String:oldValue[], const String:newValue[]) {
	OnConfigsExecuted(); //re-adjust if survivor_limit, perm health multiplier etc. are changed mid game
}

public Action:Timer_PrintScore(Handle:timer) {
	PrintScore();
}

PrintScore() {
	new iMaxBonusForMap = RoundToFloor(fMaxBonusForMap);
	new iTeamOneBonus = RoundToFloor(fBonusScore[TEAM_ONE]);
	new iTeamTwoBonus = RoundToFloor(fBonusScore[TEAM_TWO]);
	
	if (bInVersusMode) {
		if (bInSecondHalf == false) {
			PrintToChatAll("\x01[\x04SM\x01 :: Round \x031\x01] Bonus: \x05%i\x01/\x05%i\x01", iTeamOneBonus, iMaxBonusForMap);
			// [SM :: Round 1] Bonus: 487/1200 
		} else {
			PrintToChatAll("\x01[\x04SM\x01 :: Round \x032\x01] Bonus: \x05%i\x01/\x05%i\x01", iTeamTwoBonus, iMaxBonusForMap);
			// [SM :: Round 2] Bonus: 487/1200 
		}
	} else { //print map score, and total points earned so far in this campaign
		// [SM :: Map Bonus] Bonus: 487/1200 
		PrintToChatAll("\x01[\x04SM\x01 :: Distance Points] \x05%i/%i", iTeamDistancePoints, iMapDistance);
		PrintToChatAll("\x01[\x04SM\x01 :: Health Bonus] \x05%i/%i", iTeamOneBonus, iMaxBonusForMap);
		PrintToChatAll("\x01[\x04SM\x01 :: Campaign Score] \x05%i", iCampaignScore);
	}	
}

/*************************************************************************************************************

										VERSUS EVENT HOOKS
										
*************************************************************************************************************/

public Action:L4D2_OnEndVersusModeRound() { //bool:countSurvivors could possibly be used as a parameter here
	new team;
	if (!bInSecondHalf) {
		team = TEAM_ONE;
	} else {
		team = TEAM_TWO;
	}
	fBonusScore[team] = CalculateBonusScore();
	SetConVarInt(hCvarSurvivalBonus, 0); //assumption
	
	//Check if team has wiped
	new iSurvivalMultiplier = CountUprightSurvivors();
	if (iSurvivalMultiplier == 0) { 
		PrintToChatAll("Survivors wiped out");
		return Plugin_Continue;
	} else if (fBonusScore[team] <= 0) {
		PrintToChatAll("Bonus depleted");
	} else {
		//Set score (awarded on a per survivor basis -> divide calculated bonus by number of standing survivors)
		SetConVarInt(hCvarSurvivalBonus, RoundToFloor(fBonusScore[team]/iSurvivalMultiplier) );
		// Scores print
		CreateTimer(3.0, Timer_PrintScore, _, TIMER_FLAG_NO_MAPCHANGE);
		bIsRoundOver = true;
	}	
	return Plugin_Continue;
}

/*************************************************************************************************************
										
										COOP EVENT HOOKS
										
*************************************************************************************************************/

public OnMissionLost() {
	//Get distance points from incapped survivors only
	//Dead survivor points are added in OnMapTransition()
	for (new client = 1; client <= MaxClients; client++) {
		if(IsClientInGame(client) && L4D2_Team:GetClientTeam(client) == L4D2Team_Survivor) {
			if (IsPlayerAlive(client)) {
				iTeamDistancePoints += GetSurvivorMapDist(client);
			}
		}
	}
}

public Action:OnMapTransition(Handle:event, const String:eventName[], bool:dontBroadcast) {
	if (!bInVersusMode) {
		//Get the health bonus for this map
		fBonusScore[TEAM_ONE] = CalculateBonusScore();
		new iBonusEarned = RoundToFloor(fBonusScore[TEAM_ONE]);
		
		//Get distance points for survivors that have made saferoom				
		new iNumMadeSaferoom = CountUprightSurvivors();
		new Float:fProportionOfTeam = float(iNumMadeSaferoom)/float(iTeamSize);
		iTeamDistancePoints += RoundToNearest(fProportionOfTeam * iMapDistance);
		
		//Add distance points from survivors that have died
		iTeamDistancePoints += iDeadSurvivorDistPoints;		
		iCampaignScore += iTeamDistancePoints; 
		iCampaignScore += iBonusEarned;
		
		//Use this convar to save accumulated score in coop; also makes the health bonus available for vscripts to access
		//SetConVarInt(hCvarTieBreaker, iCampaignScore);
		
		// Scores print
		PrintScore();
		
		// Check if Mapskipper.smx is indicating score needs to be reset
		if (GetEventBool(event, "finale")) {
			LogMessage("Finale finished, resetting score");
			iCampaignScore = 0;
		}
		bIsRoundOver = true;
	} 
}

//map_transition event does not work for last map in a campaign
public OnFinaleFinish() { 
	if (!bInVersusMode) {
		//Get the health bonus for this map
		fBonusScore[TEAM_ONE] = CalculateBonusScore();
		new iBonusEarned = RoundToFloor(fBonusScore[TEAM_ONE]);
		//Get the distance points				
		new iNumMadeSaferoom = CountUprightSurvivors();
		new Float:fProportionOfTeam = float(iNumMadeSaferoom)/float(iTeamSize);
		iTeamDistancePoints += RoundToNearest(fProportionOfTeam * iMapDistance); //points from survivors that made saferoom
		iTeamDistancePoints += iDeadSurvivorDistPoints;		
		iCampaignScore += iTeamDistancePoints + iBonusEarned;
		//Use this convar to save accumulated score in coop; also makes the health bonus available for vscripts to access
		//SetConVarInt(hCvarTieBreaker, iCampaignScore);
		// Scores print
		PrintScore();
		bIsRoundOver = true;
	} 
}

// Get their distance points before it is lost on death
public Action:OnPlayerDeath(Handle:event, const String:name[], bool:dontBroadcast) { 
	new userid = GetEventInt(event, "userid");
	new client = GetClientOfUserId(userid);
	if (IsValidClient(client) && IsSurvivor(client)) {
		iDeadSurvivorDistPoints += GetSurvivorMapDist(client);
	}	
}

// reset for new map/survivors wiping
public OnRoundFreezeEnd() { 
	iDeadSurvivorDistPoints = 0; 
}

/*************************************************************************************************************
											
											PLUGIN COMMANDS
											
*************************************************************************************************************/

public Action:CmdScoring(client, args) {
	PrintToChat(client, "\x03<Health bonus pool - breakdown>");
	PrintToChat(client, "\x04Permanent health ->\x05 x%f \x01(default 1.5)", GetConVarFloat(hCVarPermHealthMultiplier));
	PrintToChat(client, "\x01- Held perm health:		\x05100");
	PrintToChat(client, "\x04Temporary health ->\x05 x1.0 \x01");
	PrintToChat(client, "\x01- Held temp health:		\x05 __");
	PrintToChat(client, "\x01- Starting pill bonus:		\x05 50");
	PrintToChat(client, "\x01- Incap Avoidance bonus:	\x05 30 per incap avoided \x01(2 max incaps per survivor)");
	PrintToChat(client, "\x03Each survivor contributes 100*1.5 + 50 + 60 =\x05 260 \x01bonus");
	PrintToChat(client, "\x03 -> total 4v4 \x04starting bonus \x03of 4x260 =\x05 1040 \x01(before map multiplier)");
	PrintToChat(client, "\x04Only temporary health gained from eating the starting set of pills will convert into bonus");
	PrintToChat(client, "");
	return Plugin_Handled;
}

public Action:CmdMapInfo(client, args) {
	if (client <= 0) {
		PrintToServer("\x01[\x04SM\x01 :: \x03%iv%i\x01] Map Info", iTeamSize, iTeamSize); // [SM :: 4v4] Map Info
		PrintToServer("\x04Map Distance: \x05%i\x01", iMapDistance);
		PrintToServer("\x04Map Multiplier: \x05%f\x01", GetMapMultiplier()); // Map multiplier
		PrintToServer("\x04Max bonus for this map: \x05%f", fMaxBonusForMap);
		PrintToServer("");
	} else {
		PrintToChat(client, "\x01[\x04SM\x01 :: \x03%iv%i\x01] Map Info", iTeamSize, iTeamSize); // [SM :: 4v4] Map Info
		PrintToChat(client, "\x04Map Distance: \x05%i\x01", iMapDistance);
		PrintToChat(client, "\x04Map Multiplier: \x05%f\x01", GetMapMultiplier()); // Map multiplier
		PrintToChat(client, "\x04Max bonus for this map: \x05%f", fMaxBonusForMap);
		PrintToChat(client, "");
	}
	return Plugin_Handled;
}

//For coop
public Action:CmdSetScore(client, args) {
	if (bInVersusMode) {
		PrintToServer("Score can only be set in coop");
	} else {
		new String:arg[32];
		if (args == 1 && GetCmdArg(1, arg, sizeof(arg))) {			
			iCampaignScore = StringToInt(arg); // the bonus value to be set
			//SetConVarInt(hCvarTieBreaker, iCampaignScore);
			PrintToChatAll("Campaign score set to %i", iCampaignScore);
		} else {
			PrintToChat(client, "Must input a valid score value");
		}		
	}	
}

public Action:CmdScore(client, args) { // [SM :: R#1] Bonus: 556

	#if SM_DEBUG
		PrintToChatAll("CmdBonus()");
	#endif
	
	if (bIsRoundOver) {
		
		#if SM_DEBUG
			if (bIsRoundOver) {
				PrintToChatAll("bIsRoundOver: true ");
			}				
		#endif
		return Plugin_Handled;
		
	} else {
		new iMaxBonusForMap = RoundToFloor(fMaxBonusForMap);
		new iBonus = RoundToFloor(CalculateBonusScore());
		new bool:bIsSilentCommand = (client > 0 ? false : true); //sm_command instead of !command chat trigger?
		if (!bInVersusMode) { //print without a round number
			if (bIsSilentCommand) { 
				PrintToServer("\x01[\x04SM\x01 :: Health Bonus] \x05%d/%d\x01", iBonus, iMaxBonusForMap);
				PrintToServer("\x01[\x04SM\x01 :: Campaign Score] \x05%d\x01", iCampaignScore);
			} else {
				PrintToChat(client, "\x01[\x04SM\x01 :: Health Bonus] \x05%d/%d\x01", iBonus, iMaxBonusForMap);
				PrintToChat(client, "\x01[\x04SM\x01 :: Campaign Score] \x05%d\x01", iCampaignScore);
			}			
		} else {
			//boolean values are stored as '0' for false or '1' for true
			new iRoundNum = _:(bInSecondHalf) + 1;
			if (bIsSilentCommand) { 
				PrintToServer("\x01[\x04SM\x01 :: R\x03#%i\x01] Bonus: \x05%d/%d\x01", iRoundNum, iBonus, iMaxBonusForMap);
			} else {
				PrintToChat(client, "\x01[\x04SM\x01 :: R\x03#%i\x01] Bonus: \x05%d/%d\x01", iRoundNum, iBonus, iMaxBonusForMap);
			}	
		}
		return Plugin_Continue;
	}	
}

/*************************************************************************************************************
											
											HEALTH BONUS CALCULATION
											
*************************************************************************************************************/

 // Apply map multiplier to the sum of the permanent and temporary health bonuses
Float:CalculateBonusScore() {
	
	if (CountUprightSurvivors() == 0) { return 0.0; } //wiped; no bonus
	new Float:fPermBonus = GetPermBonus();
	new Float:fTempBonus = GetTempBonus();
	new Float:fMapMultiplier = GetMapMultiplier();
	new Float:fHealth = fPermBonus + fTempBonus;
	new Float:fHealthBonus = fHealth * fMapMultiplier;
	
	#if SM_DEBUG
		PrintToChatAll("\x03CalculateBonusScore()");
		PrintToChatAll("\x04Total health pool: \x05%f", fHealth);
		PrintToChatAll("\x04MapMultiplier: \x05%f", fMapMultiplier);
		PrintToChatAll("\x03-> HealthBonus: \x05%f", fHealthBonus);
		PrintToChatAll(" ");
	#endif
	
	return fHealthBonus;
}

// Permanent health held * multiplier(default value 1.5)
Float:GetPermBonus() { 
	new iPermHealthPool = 0;
	#if SM_DEBUG
		PrintToChatAll("\x04GetPermBonus()");
		PrintToChatAll( "Permanent Health Multiplier: \x05%f", GetConVarFloat(hCVarPermHealthMultiplier) );
	#endif
	for (new client = 1; client < MaxClients; client++) {
		
		//Add permanent health held by each non-incapped survivor
		if (IsSurvivor(client) && IsPlayerAlive(client) && !IsPlayerIncap(client) ) { 
			
			if (GetEntProp(client, Prop_Send, "m_currentReviveCount") == 0 ) {
				
				if (GetEntProp(client, Prop_Send, "m_iHealth") > 0) {
					new iThisSurvivorsPermHealth = GetEntProp(client, Prop_Send, "m_iHealth");
					iPermHealthPool += iThisSurvivorsPermHealth;
					
					#if SM_DEBUG
						PrintToChatAll("- Found a survivor with \x05%d \x04perm health", iThisSurvivorsPermHealth);
					#endif
					
				} 
			}
		}
	}		
	
	new Float:fPermHealthBonus = iPermHealthPool * GetConVarFloat(hCVarPermHealthMultiplier);

	#if SM_DEBUG
		PrintToChatAll("\x03'Permanent Health' Bonus = \x05%f", fPermHealthBonus);
	#endif
	
	return (fPermHealthBonus > 0 ? fPermHealthBonus: 0.0);
}

/*
 * Start with temp health held by survivors
 * Temp bonus is the same as temp health because of the x1 TEMP_HEALTH_MULTIPLIER
 * -> subtract an 'incap penalty' to accommodate temp bonus gained when picked up  
 * -> subtract a 'scavenged pills penalty' to accommodate temp bonus gained from non-starting pills
 */
Float:GetTempBonus() { 
	#if SM_DEBUG
		PrintToChatAll("\x04GetTempBonus()");
	#endif
	
	new iTempHealthPool = 0; //the team's collective temp health pool
	new iIncapsSuffered = 0; 
	for (new client = 1; client < MaxClients; client++) {
		
		if (IsSurvivor(client) && !IsPlayerIncap(client)) { //incapped survivors are granted 300 temp health until revival	
		
			if (IsPlayerAlive(client)) { 				
				//count incaps, add temp health to pool
				iIncapsSuffered += GetEntProp(client, Prop_Send, "m_currentReviveCount"); 
				new iThisSurvivorsTempHealth = RoundToCeil(GetEntPropFloat(client, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime")) * GetConVarFloat(FindConVar("pain_pills_decay_rate")))) - 1;
				
				if (iThisSurvivorsTempHealth > 0) {
					//Add temp health held by each survivor
					iTempHealthPool += iThisSurvivorsTempHealth;
					
					#if SM_DEBUG
						PrintToChatAll("- Found a survivor with \x05%i \x04temp health", iThisSurvivorsTempHealth);
					#endif		
						
				} 
				
				else {
					
					#if SM_DEBUG
						PrintToChatAll("- Found a survivor with no temp health");
					#endif
					
				}		
				
			} 
			
			//dead survivor, penalise for 2 incaps 
			else { 
				iIncapsSuffered += INCAPS_BEFORE_DEATH;	
				
				#if SM_DEBUG
					PrintToChatAll("- Found a dead survivor");
				#endif
				
			}			
		}
	}	
	
			#if SM_DEBUG
				PrintToChatAll("\x03'Temporary Health' Bonus =");
				PrintToChatAll("\x04+ temp health held: \x05%i", iTempHealthPool);
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
				PrintToChatAll("\x04+ Starting Pill Bonus: \x05%i", iStartingPillBonus);
				PrintToChatAll("\x04+ Incap Avoidance Bonus: \x05%i", iIncapAvoidanceBonus);
				PrintToChatAll("\x04- Pill Consumption Penalty: \x05%i", iPillConsumptionPenalty);
				PrintToChatAll("\x03= \x05%f", fTempHealthBonus);
			#endif
	
	return (fTempHealthBonus > 0 ? fTempHealthBonus : 0.0);
}

// (2 * Map Distance)/Max health bonus (1040 by default w/ 1.5 perm health multiplier)
Float:GetMapMultiplier() { 
	new Float:fMaxPermBonus = MAX_HEALTH * GetConVarFloat(hCVarPermHealthMultiplier);
	new iSurvivorIncapHealth = INCAP_HEALTH * INCAPS_BEFORE_DEATH; // 30 x 2
	new Float:fMapMultiplier = ( 2 * iMapDistance )/( iTeamSize*(fMaxPermBonus + STARTING_PILL_BONUS + iSurvivorIncapHealth));
	return fMapMultiplier;
}

/*************************************************************************************************************
											
											UTILITY FUNCTIONS
											
*************************************************************************************************************/

GetSurvivorMapDist(client) {
	decl Float:fFlowCovered;
	decl Float:origin[3];
	decl Address:pNavArea;
	if(IsClientInGame(client) && L4D2_Team:GetClientTeam(client) == L4D2Team_Survivor) {
		GetClientAbsOrigin(client, origin);
		pNavArea = L4D2Direct_GetTerrorNavArea(origin);
		if (pNavArea != Address_Null) {
			fFlowCovered = L4D2Direct_GetTerrorNavAreaFlow(pNavArea);
			new Float:fDistanceProportion = fFlowCovered/L4D2Direct_GetMapMaxFlowDistance();
			new iThisSurvivorDistPoints = RoundToNearest(fDistanceProportion * (iMapDistance/iTeamSize));
			// survivors spawning at the back of the saferoom start with negative distance points; give them 0 instead:
			iThisSurvivorDistPoints = (iThisSurvivorDistPoints > 0 ? iThisSurvivorDistPoints : 0); 
			#if SM_DEBUG
				new String:ClientName[256];
				GetClientName(client, ClientName, sizeof(ClientName));
				PrintToChatAll("\x04Distance covered by %s:", ClientName);
				PrintToChatAll("- flow distance:			\x05%f", fFlowCovered);
				PrintToChatAll("- max flow distance:		\x05%f", L4D2Direct_GetMapMaxFlowDistance());
				PrintToChatAll("- proportion of total flow:	\x05%f", fDistanceProportion);
				PrintToChatAll("- map distance points: 		\x05%i", iThisSurvivorDistPoints);
			#endif 
			return iThisSurvivorDistPoints;
		}
	}
	return 0; // no distance points found for client
}

CheckGameMode() 
{
    // check if it is versus
    new String:tmpStr[24];
    GetConVarString( FindConVar("mp_gamemode"), tmpStr, sizeof(tmpStr) );
    if ( StrEqual(tmpStr, "versus", false) ) {
        bInVersusMode = true;
    }
}

CountUprightSurvivors() {
	new iUprightCount = 0;
	new iSurvivorCount = 0;
	for (new i = 1; i <= MaxClients && iSurvivorCount < iTeamSize; i++) {
		if (IsSurvivor(i)) {
			iSurvivorCount++;
			if (IsPlayerAlive(i) && !IsPlayerIncap(i) && !IsPlayerLedged(i)) {
				iUprightCount++;
			}
		}
	}
	#if SM_DEBUG
		PrintToChatAll("CountUprightSurvivors() -> %i", iUprightCount);
	#endif
	return iUprightCount;
}

bool:IsValidClient(iClient) {
    return (iClient > 0 && iClient <= MaxClients);
}

bool:IsPlayerIncap(client) {
	return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated");
}

bool:IsPlayerLedged(client)
{
	return bool:(GetEntProp(client, Prop_Send, "m_isHangingFromLedge") | GetEntProp(client, Prop_Send, "m_isFallingFromLedge"));
}	