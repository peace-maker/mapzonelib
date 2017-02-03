#pragma semicolon 1
#include <sourcemod>
#include <mapzonelib>
#include <smlib>

#define PLUGIN_VERSION "1.0"

#define MAX_ZONE_GROUP_NAME 64

#define XYZ(%1) %1[0], %1[1], %1[2]

enum ZoneData {
	ZD_index,
	ZD_triggerEntity,
	ZD_clusterIndex,
	ZD_teamFilter,
	ZD_color[4],
	Handle:ZD_customKV,
	Float:ZD_position[3],
	Float:ZD_mins[3],
	Float:ZD_maxs[3],
	Float:ZD_rotation[3],
	bool:ZD_deleted, // We can't directly delete zones, because we use the array index as identifier. Deleting would mean an array shiftup.
	bool:ZD_clientInZone[MAXPLAYERS+1], // List of clients in this zone.
	bool:ZD_adminShowZone[MAXPLAYERS+1], // List of clients which want to see this zone.
	String:ZD_name[MAX_ZONE_NAME],
	String:ZD_triggerModel[PLATFORM_MAX_PATH] // Name of the brush model of the trigger which fits this zone best.
}

enum ZoneCluster {
	ZC_index,
	bool:ZC_deleted,
	ZC_teamFilter,
	ZC_color[4],
	Handle:ZC_customKV,
	bool:ZC_adminShowZones[MAXPLAYERS+1],  // Just to remember if we want to toggle all zones in this cluster on or off.
	ZC_clientInZones[MAXPLAYERS+1], // Save for each player in how many zones of this cluster he is.
	String:ZC_name[MAX_ZONE_NAME]
};

enum ZoneGroup {
	ZG_index,
	Handle:ZG_zones,
	Handle:ZG_cluster,
	Handle:ZG_menuBackForward,
	ZG_filterEntTeam[2], // Filter entities for teams
	bool:ZG_showZones,
	bool:ZG_adminShowZones[MAXPLAYERS+1], // Just to remember if we want to toggle all zones in this group on or off.
	ZG_defaultColor[4],
	String:ZG_name[MAX_ZONE_GROUP_NAME]
}

enum ZoneEditState {
	ZES_first,
	ZES_second,
	ZES_name
}

enum ZonePreviewMode {
	ZPM_aim,
	ZPM_feet
}

// The different step sizes when modifying one point of a zone the user can choose from.
#define DEFAULT_STEPSIZE_INDEX 3
new Float:g_fStepsizes[] = {1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0};

enum ClientMenuState {
	CMS_group,
	CMS_cluster,
	CMS_zone,
	bool:CMS_rename,
	bool:CMS_addZone,
	bool:CMS_addCluster,
	bool:CMS_editRotation,
	bool:CMS_editCenter,
	bool:CMS_editPosition,
	ZoneEditState:CMS_editState,
	ZonePreviewMode:CMS_previewMode,
	bool:CMS_disablePreview, // Used to not show a preview while in the axes modification menu.
	CMS_stepSizeIndex, // index into g_fStepsizes array currently used by the client.
	Float:CMS_aimCapDistance, // How far away can the aim target wall be at max?
	bool:CMS_redrawPointMenu, // Player is currently changing the cap distance using right click?
	bool:CMS_snapToGrid, // Snap to the nearest grid corner when assuming a grid size of CMS_stepSizeIndex.
	Float:CMS_first[3],
	Float:CMS_second[3],
	Float:CMS_rotation[3],
	Float:CMS_center[3]
}

enum ClientClipBoard {
	Float:CB_mins[3],
	Float:CB_maxs[3],
	Float:CB_position[3],
	Float:CB_rotation[3],
	String:CB_name[MAX_ZONE_NAME]
}

new Handle:g_hCVShowZonesDefault;
new Handle:g_hCVOptimizeBeams;
new Handle:g_hCVDebugBeamDistance;
new Handle:g_hCVMinHeight;
new Handle:g_hCVDefaultHeight;

new Handle:g_hfwdOnEnterForward;
new Handle:g_hfwdOnLeaveForward;

// Displaying of zones using laser beams
new Handle:g_hShowZonesTimer;
new g_iLaserMaterial = -1;
new g_iHaloMaterial = -1;
new g_iGlowSprite = -1;

// Central array to save all information about zones
new Handle:g_hZoneGroups;

// Support for browsing through nested menus
new g_ClientMenuState[MAXPLAYERS+1][ClientMenuState];
// Copy & paste zones even over different groups.
new g_Clipboard[MAXPLAYERS+1][ClientClipBoard];
// Show the crosshair and current zone while adding/editing a zone.
new Handle:g_hShowZoneWhileEditTimer[MAXPLAYERS+1];
// Temporary store the angles the player looked at when starting 
// to press +attack2 to keep the view and laser point steady.
new Float:g_fAimCapTempAngles[MAXPLAYERS+1][3];
// Store the buttons the player pressed in the previous frame, so we know when he started to press something.
new g_iClientButtons[MAXPLAYERS+1];

public Plugin:myinfo = 
{
	name = "Map Zone Library",
	author = "Peace-Maker",
	description = "Manages zones on maps and fires forwards, when players enter or leave the zone.",
	version = PLUGIN_VERSION,
	url = "http://www.wcfan.de/"
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("MapZone_RegisterZoneGroup", Native_RegisterZoneGroup);
	CreateNative("MapZone_ShowMenu", Native_ShowMenu);
	CreateNative("MapZone_SetMenuBackAction", Native_SetMenuBackAction);
	CreateNative("MapZone_SetZoneDefaultColor", Native_SetZoneDefaultColor);
	CreateNative("MapZone_SetZoneColor", Native_SetZoneColor);
	CreateNative("MapZone_SetClientZoneVisibility", Native_SetClientZoneVisibility);
	CreateNative("MapZone_GetGroupZones", Native_GetGroupZones);
	CreateNative("MapZone_IsClusteredZone", Native_IsClusteredZone);
	CreateNative("MapZone_GetClusterZones", Native_GetClusterZones);
	CreateNative("MapZone_GetCustomString", Native_GetCustomString);
	CreateNative("MapZone_SetCustomString", Native_SetCustomString);
	RegPluginLibrary("mapzonelib");
	return APLRes_Success;
}

public OnPluginStart()
{
	// forward MapZone_OnClientEnterZone(client, const String:sZoneGroup[], const String:sZoneName[]);
	g_hfwdOnEnterForward = CreateGlobalForward("MapZone_OnClientEnterZone", ET_Ignore, Param_Cell, Param_String, Param_String);
	// forward MapZone_OnClientLeaveZone(client, const String:sZoneGroup[], const String:sZoneName[]);
	g_hfwdOnLeaveForward = CreateGlobalForward("MapZone_OnClientLeaveZone", ET_Ignore, Param_Cell, Param_String, Param_String);
	g_hZoneGroups = CreateArray(_:ZoneGroup);
	
	LoadTranslations("common.phrases");
	
	g_hCVShowZonesDefault = CreateConVar("sm_mapzone_showzones", "0", "Show all zones to all players by default?", _, true, 0.0, true, 1.0);
	g_hCVOptimizeBeams = CreateConVar("sm_mapzone_optimize_beams", "1", "Try to hide zones from players, that aren't able to see them?", _, true, 0.0, true, 1.0);
	g_hCVDebugBeamDistance = CreateConVar("sm_mapzone_debug_beamdistance", "5000", "Only show zones that are as close as up to x units to the player.", _, true, 0.0);
	g_hCVMinHeight = CreateConVar("sm_mapzone_minheight", "10", "Snap to the default_height if zone is below this height.", _, true, 0.0);
	g_hCVDefaultHeight = CreateConVar("sm_mapzone_default_height", "128", "The default height of a zone when it's below the minimum height. 0 to disable.", _, true, 0.0);
	
	AutoExecConfig(true, "plugin.mapzonelib");
	
	HookConVarChange(g_hCVShowZonesDefault, ConVar_OnDebugChanged);
	
	HookEvent("round_start", Event_OnRoundStart);
	HookEvent("player_spawn", Event_OnPlayerSpawn);
	HookEvent("player_death", Event_OnPlayerDeath);
	
	// Clear menu states
	for(new i=1;i<=MaxClients;i++)
		OnClientDisconnect(i);
}

public OnPluginEnd()
{
	// Map might not be loaded anymore on server shutdown.
	// Don't create a ".zones" file. OnMapEnd would have been called before, 
	// so the zones are saved.
	new String:sMap[32];
	if (!GetCurrentMap(sMap, sizeof(sMap)))
		return;
	
	SaveAllZoneGroupsToFile();
	
	// Kill all created trigger_multiple.
	new iNumGroups = GetArraySize(g_hZoneGroups);
	new iNumZones, group[ZoneGroup], zoneData[ZoneData];
	for(new i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		iNumZones = GetArraySize(group[ZG_zones]);
		for(new c=0;c<iNumZones;c++)
		{
			GetZoneByIndex(c, group, zoneData);
			RemoveZoneTrigger(group, zoneData);
		}
	}
}

/**
 * Core forward callbacks
 */
public OnMapStart()
{
	PrecacheModel("models/error.mdl", true);

	// Don't want to redefine the default sprites.
	// Borrow them for different games from sm's default funcommands plugin.
	new Handle:hGameConfig = LoadGameConfigFile("funcommands.games");
	if (!hGameConfig)
	{
		SetFailState("Unable to load game config funcommands.games from stock sourcemod plugin for beam materials.");
		return;
	}
	
	new String:sBuffer[PLATFORM_MAX_PATH];
	if (GameConfGetKeyValue(hGameConfig, "SpriteBeam", sBuffer, sizeof(sBuffer)) && sBuffer[0])
	{
		g_iLaserMaterial = PrecacheModel(sBuffer, true);
	}
	
	if (GameConfGetKeyValue(hGameConfig, "SpriteHalo", sBuffer, sizeof(sBuffer)) && sBuffer[0])
	{
		g_iHaloMaterial = PrecacheModel(sBuffer, true);
	}
	
	if (GameConfGetKeyValue(hGameConfig, "SpriteGlow", sBuffer, sizeof(sBuffer)) && sBuffer[0])
	{
		g_iGlowSprite = PrecacheModel(sBuffer, true);
	}
	
	CloseHandle(hGameConfig);
	
	// Remove all zones of the old map
	ClearZonesInGroups();
	// Load all zones for the current map for all registered groups
	LoadAllGroupZones();
	// Spawn the trigger_multiples for all zones
	SetupAllGroupZones();
	
	g_hShowZonesTimer = CreateTimer(2.0, Timer_ShowZones, _, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
}

public OnMapEnd()
{
	SaveAllZoneGroupsToFile();
	g_hShowZonesTimer = INVALID_HANDLE;
}

public OnClientDisconnect(client)
{
	g_ClientMenuState[client][CMS_group] = -1;
	g_ClientMenuState[client][CMS_cluster] = -1;
	g_ClientMenuState[client][CMS_zone] = -1;
	g_ClientMenuState[client][CMS_rename] = false;
	g_ClientMenuState[client][CMS_addCluster] = false;
	g_ClientMenuState[client][CMS_editRotation] = false;
	g_ClientMenuState[client][CMS_editCenter] = false;
	g_ClientMenuState[client][CMS_editPosition] = false;
	g_ClientMenuState[client][CMS_previewMode] = ZPM_aim;
	g_ClientMenuState[client][CMS_disablePreview] = false;
	g_ClientMenuState[client][CMS_stepSizeIndex] = DEFAULT_STEPSIZE_INDEX;
	g_ClientMenuState[client][CMS_aimCapDistance] = -1.0;
	g_ClientMenuState[client][CMS_redrawPointMenu] = false;
	g_ClientMenuState[client][CMS_snapToGrid] = false;
	Array_Fill(g_ClientMenuState[client][CMS_rotation], 3, 0.0);
	Array_Fill(g_ClientMenuState[client][CMS_center], 3, 0.0);
	ResetZoneAddingState(client);
	g_iClientButtons[client] = 0;
	
	ClearClientClipboard(client);
	
	// If he was in some zone, guarantee to call the leave callback.
	RemoveClientFromAllZones(client);
	
	new iNumGroups = GetArraySize(g_hZoneGroups);
	new iNumClusters, iNumZones;
	new group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
	for(new i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		group[ZG_adminShowZones][client] = false;
		SaveGroup(group);
		
		iNumZones = GetArraySize(group[ZG_cluster]);
		for(new z=0;z<iNumZones;z++)
		{
			GetZoneByIndex(z, group, zoneData);
			// Doesn't want to see zones anymore.
			zoneData[ZD_adminShowZone][client] = false;
			SaveZone(group, zoneData);
		}
		
		// Client is no longer in any clusters.
		// Just to make sure.
		iNumClusters = GetArraySize(group[ZG_cluster]);
		for(new c=0;c<iNumClusters;c++)
		{
			GetZoneClusterByIndex(c, group, zoneCluster);
			zoneCluster[ZC_clientInZones][client] = 0;
			zoneCluster[ZC_adminShowZones][client] = false;
			SaveCluster(group, zoneCluster);
		}
	}
}

public Action:OnClientSayCommand(client, const String:command[], const String:sArgs[])
{
	if(g_ClientMenuState[client][CMS_rename])
	{
		g_ClientMenuState[client][CMS_rename] = false;
	
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		
		if(g_ClientMenuState[client][CMS_zone] != -1)
		{
			new zoneData[ZoneData];
			GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
			
			if(!StrContains(sArgs, "!abort"))
			{
				PrintToChat(client, "Map Zones > Renaming of zone \"%s\" stopped.", zoneData[ZD_name]);
				DisplayZoneEditMenu(client);
				return Plugin_Handled;
			}
			
			// Make sure the name is unique in this group.
			if(ZoneExistsWithName(group, sArgs))
			{
				PrintToChat(client, "Map Zones > There is a zone called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
				return Plugin_Handled;
			}
			
			if(ClusterExistsWithName(group, sArgs))
			{
				PrintToChat(client, "Map Zones > There is a cluster called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
				return Plugin_Handled;
			}

			PrintToChat(client, "Map Zones > Zone \"%s\" renamed to \"%s\".", zoneData[ZD_name], sArgs);
			
			strcopy(zoneData[ZD_name], MAX_ZONE_NAME, sArgs);
			SaveZone(group, zoneData);
			
			DisplayZoneEditMenu(client);
			return Plugin_Handled;
		}
		else if(g_ClientMenuState[client][CMS_cluster] != -1)
		{
			new zoneCluster[ZoneCluster];
			GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
			
			if(!StrContains(sArgs, "!abort"))
			{
				PrintToChat(client, "Map Zones > Renaming of cluster \"%s\" stopped.", zoneCluster[ZC_name]);
				DisplayClusterEditMenu(client);
				return Plugin_Handled;
			}
			
			// Make sure the cluster name is unique in this group.
			if(ClusterExistsWithName(group, sArgs))
			{
				PrintToChat(client, "Map Zones > There is a cluster called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
				return Plugin_Handled;
			}
			
			if(ZoneExistsWithName(group, sArgs))
			{
				PrintToChat(client, "Map Zones > There is a zone called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
				return Plugin_Handled;
			}
			
			strcopy(zoneCluster[ZC_name], MAX_ZONE_NAME, sArgs);
			SaveCluster(group, zoneCluster);
			
			PrintToChat(client, "Map Zones > Cluster \"%s\" renamed to \"%s\".", zoneCluster[ZC_name], sArgs);
			DisplayClusterEditMenu(client);
			return Plugin_Handled;
		}
	}
	else if(g_ClientMenuState[client][CMS_addZone] && g_ClientMenuState[client][CMS_editState] == ZES_name)
	{
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		
		if(!StrContains(sArgs, "!abort"))
		{
			// When pasting a zone from the clipboard, 
			// we want to edit the center position right away afterwards.
			if(g_ClientMenuState[client][CMS_editCenter])
				PrintToChat(client, "Map Zones > Aborted pasting of zone from clipboard.");
			else
				PrintToChat(client, "Map Zones > Aborted adding of new zone.");
			
			ResetZoneAddingState(client);
			
			// In case we tried to paste a zone.
			g_ClientMenuState[client][CMS_editCenter] = false;
			
			if(g_ClientMenuState[client][CMS_cluster] == -1)
			{
				DisplayGroupRootMenu(client, group);
			}
			else
			{
				// With CMS_cluster set, this adds to the cluster.
				DisplayZoneListMenu(client);
			}
			return Plugin_Handled;
		}
		
		if(ZoneExistsWithName(group, sArgs))
		{
			PrintToChat(client, "Map Zones > There is a zone called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
			return Plugin_Handled;
		}
		
		if(ClusterExistsWithName(group, sArgs))
		{
			PrintToChat(client, "Map Zones > There is a cluster called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
			return Plugin_Handled;
		}
		
		SaveNewZone(client, sArgs);
		return Plugin_Handled;
	}
	else if(g_ClientMenuState[client][CMS_addCluster])
	{
		// We can get here when adding a cluster through the Cluster List menu from the main menu
		// or when adding a zone to a cluster and adding a new cluster this zone should be part of right away.
		new bool:bIsEditingZone = g_ClientMenuState[client][CMS_zone] != -1;
		
		if(!StrContains(sArgs, "!abort"))
		{
			g_ClientMenuState[client][CMS_addCluster] = false;
			
			PrintToChat(client, "Map Zones > Aborted adding of new cluster.");
			if (bIsEditingZone)
				DisplayClusterSelectionMenu(client);
			else
				DisplayClusterListMenu(client);
			return Plugin_Handled;
		}
		
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		
		// Make sure the cluster name is unique in this group.
		if(ClusterExistsWithName(group, sArgs))
		{
			PrintToChat(client, "Map Zones > There is a cluster called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
			return Plugin_Handled;
		}
		
		if(ZoneExistsWithName(group, sArgs))
		{
			PrintToChat(client, "Map Zones > There is a zone called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
			return Plugin_Handled;
		}
		
		g_ClientMenuState[client][CMS_addCluster] = false;
		
		new zoneCluster[ZoneCluster];
		strcopy(zoneCluster[ZC_name], MAX_ZONE_NAME, sArgs);
		// Don't use a seperate color for this cluster by default.
		zoneCluster[ZC_color][0] = -1;
		zoneCluster[ZC_index] = GetArraySize(group[ZG_cluster]);
		PushArrayArray(group[ZG_cluster], zoneCluster[0], _:ZoneCluster);
		
		PrintToChat(client, "Map Zones > Added new cluster \"%s\".", zoneCluster[ZC_name]);
		
		// Add the currently edited zone to the new cluster right away.
		if (bIsEditingZone)
		{
			new zoneData[ZoneData];
			GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);

			PrintToChat(client, "Map Zones > Zone \"%s\" is now part of cluster \"%s\".", zoneData[ZD_name], zoneCluster[ZC_name]);
		
			zoneData[ZD_clusterIndex] = zoneCluster[ZC_index];
			SaveZone(group, zoneData);
			DisplayZoneEditMenu(client);
		}
		else
		{
			g_ClientMenuState[client][CMS_cluster] = zoneCluster[ZC_index];
			DisplayClusterEditMenu(client);
		}
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	static s_tickinterval[MAXPLAYERS+1];
	
	// Client is currently editing or adding a zone point.
	new iRemoveButtons;
	if (IsClientEditingZonePosition(client) && !g_ClientMenuState[client][CMS_disablePreview])
	{
		// Started pressing +use
		// See if he wants to set a zone's position.
		if(buttons & IN_USE && !(g_iClientButtons[client] & IN_USE))
		{
			new Float:fUnsnappedOrigin[3], Float:fSnappedOrigin[3], Float:fGroundNormal[3];
			GetClientFeetPosition(client, fUnsnappedOrigin, fGroundNormal);
			
			// Snap the position to the grid if user wants it.
			SnapToGrid(client, fUnsnappedOrigin, fSnappedOrigin, fGroundNormal);
			
			HandleZonePositionSetting(client, fSnappedOrigin);
			
			// Don't let that action go through.
			iRemoveButtons |= IN_USE;
		}
		
		// Started pressing +attack
		// See if he wants to set a zone's position.
		if(buttons & IN_ATTACK && !(g_iClientButtons[client] & IN_ATTACK))
		{
			new Float:fAimPosition[3], Float:fUnsnappedAimPosition[3];
			if (GetClientZoneAimPosition(client, fAimPosition, fUnsnappedAimPosition))
				HandleZonePositionSetting(client, fAimPosition);
			// Don't let that action go through.
			iRemoveButtons |= IN_ATTACK;
		}
		
		// Presses +attack2!
		// Save current view angles and move the aim target distance cap according to his mouse moving up and down.
		if(buttons & IN_ATTACK2 && g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
		{
			// Started pressing +attack2?
			// Save the current angles as a reference.
			if (!(g_iClientButtons[client] & IN_ATTACK2))
			{
				g_fAimCapTempAngles[client] = angles;
				s_tickinterval[client] = 0;
			}
			// Wait until the laserpointer drawing set the aimcap distance, if enabling it for the first time.
			// Only change the culling distance every 10 ticks, so it's not too fast.
			else if (g_ClientMenuState[client][CMS_aimCapDistance] >= 0.0 && s_tickinterval[client] % 10)
			{
				// Change the maximal aim distance according to the mouse up & down movement.
				g_ClientMenuState[client][CMS_aimCapDistance] += g_fAimCapTempAngles[client][0] - angles[0];
				
				// Don't let the distance go behind the player.
				if(g_ClientMenuState[client][CMS_aimCapDistance] < 0.0)
				{
					g_ClientMenuState[client][CMS_aimCapDistance] = 0.0;
				}
				
				g_ClientMenuState[client][CMS_redrawPointMenu] = true;
				DisplayZonePointEditMenu(client);
				// TODO: Maybe seperate the g_fAimCapTempAngles and the point the laser should be displayed?
				// So moving the mouse after it reached the limit moves the point right away again.
			}
			
			// Keep track how often the RunCmd callback was called since the player started pressing +attack2
			s_tickinterval[client]++;
			
			// Don't move the view while changing the culling limit.
			angles = g_fAimCapTempAngles[client];
			
			// Don't let that action go through.
			iRemoveButtons |= IN_ATTACK2;
		}
	}
		
	// Update the rotation and display it directly
	if(g_ClientMenuState[client][CMS_editRotation])
	{
		// Presses +use
		if(buttons & IN_USE)
		{
			new Float:fAngles[3];
			GetClientEyeAngles(client, fAngles);
			
			// Only display the laser bbox, if the player moved his mouse.
			new bool:bChanged;
			if(g_ClientMenuState[client][CMS_rotation][1] != fAngles[1])
				bChanged = true;
			
			g_ClientMenuState[client][CMS_rotation][1] = fAngles[1];
			// Pressing +speed (shift) switches X and Z axis.
			if(buttons & IN_SPEED)
			{
				if(g_ClientMenuState[client][CMS_rotation][2] != fAngles[0])
					bChanged = true;
				g_ClientMenuState[client][CMS_rotation][2] = fAngles[0];
			}
			else
			{
				if(g_ClientMenuState[client][CMS_rotation][0] != fAngles[0])
					bChanged = true;
				g_ClientMenuState[client][CMS_rotation][0] = fAngles[0];
			}
			
			// Change new rotated box, if rotation changed from previous frame.
			if(bChanged)
			{
				new group[ZoneGroup], zoneData[ZoneData];
				GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
				GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
				
				new Float:fPos[3], Float:fMins[3], Float:fMaxs[3];
				Array_Copy(zoneData[ZD_position], fPos, 3);
				Array_Copy(zoneData[ZD_mins], fMins, 3);
				Array_Copy(zoneData[ZD_maxs], fMaxs, 3);
				Array_Copy(g_ClientMenuState[client][CMS_rotation], fAngles, 3);
				
				Effect_DrawBeamBoxRotatableToClient(client, fPos, fMins, fMaxs, fAngles, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 5.0, 5.0, 2, 1.0, {0,0,255,255}, 0);
				Effect_DrawAxisOfRotationToClient(client, fPos, fAngles, Float:{10.0,10.0,10.0}, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 5.0, 5.0, 2, 1.0, 0);
			}
		}
		// Show the laser box at the new position for a longer time.
		// The above laser box is only displayed a splitsecond to produce a smoother animation.
		// Have the current rotation persist, when stopping rotating.
		else if(g_iClientButtons[client] & IN_USE)
			TriggerTimer(g_hShowZonesTimer, true);
	}
	
	g_iClientButtons[client] = buttons;
	
	// Remove the buttons after saving them, so we know when someone stopped pressing a button.
	if (iRemoveButtons != 0)
	{
		buttons &= ~iRemoveButtons;
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

public ConVar_OnDebugChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new bool:bShowZones = GetConVarBool(g_hCVShowZonesDefault);
	new iSize = GetArraySize(g_hZoneGroups);
	new group[ZoneGroup];
	for(new i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		group[ZG_showZones] = bShowZones;
		SaveGroup(group);
	}
	
	// Show all zones immediately!
	if(bShowZones)
		TriggerTimer(g_hShowZonesTimer, true);
}

/**
 * Event callbacks
 */
public Event_OnRoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	SetupAllGroupZones();
}

public Event_OnPlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(!client)
		return;
	
	// Check if the players are in one of the zones
	// THIS IS HORRBILE, but the engine doesn't really spawn players on round_start
	// if they were alive at the end of the previous round (at least in CS:S),
	// so collision checks with triggers aren't run.
	// Have them fire the leave callback on all zones they were in before respawning
	// and have the "OnTrigger" output pickup the new touch.
	new iNumGroups = GetArraySize(g_hZoneGroups);
	new iNumZones, group[ZoneGroup], zoneData[ZoneData];
	new iTrigger;
	for(new i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		iNumZones = GetArraySize(group[ZG_zones]);
		for(new z=0;z<iNumZones;z++)
		{
			GetZoneByIndex(z, group, zoneData);
			if(zoneData[ZD_deleted])
				continue;
			
			iTrigger = EntRefToEntIndex(zoneData[ZD_triggerEntity]);
			if(iTrigger == INVALID_ENT_REFERENCE)
				continue;
			
			AcceptEntityInput(iTrigger, "EndTouch", client, client);
		}
	}
}

public Event_OnPlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(!client)
		return;
	
	// Dead players are in no zones anymore.
	RemoveClientFromAllZones(client);
}

/**
 * Native callbacks
 */
// native MapZone_RegisterZoneMenu(const String:group[]);
public Native_RegisterZoneGroup(Handle:plugin, numParams)
{
	new String:sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	
	new group[ZoneGroup];
	// See if there already is a group with that name
	if(GetGroupByName(sName, group))
		return;
	
	strcopy(group[ZG_name][0], MAX_ZONE_GROUP_NAME, sName);
	group[ZG_zones] = CreateArray(_:ZoneData);
	group[ZG_cluster] = CreateArray(_:ZoneCluster);
	group[ZG_showZones] = GetConVarBool(g_hCVShowZonesDefault);
	group[ZG_menuBackForward] = INVALID_HANDLE;
	group[ZG_filterEntTeam][0] = INVALID_ENT_REFERENCE;
	group[ZG_filterEntTeam][1] = INVALID_ENT_REFERENCE;
	// Default to red color.
	group[ZG_defaultColor][0] = 255;
	group[ZG_defaultColor][3] = 255;
	
	// Load the zone details
	LoadZoneGroup(group);
	
	group[ZG_index] = GetArraySize(g_hZoneGroups);
	PushArrayArray(g_hZoneGroups, group[0], _:ZoneGroup);
}

// native bool:MapZone_ShowMenu(client, const String:group[]);
public Native_ShowMenu(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
		return false;
	}

	new String:sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(2, sName, sizeof(sName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return false;
	
	DisplayGroupRootMenu(client, group);
	return true;
}

// native bool:MapZone_SetZoneDefaultColor(const String:group[], const iColor[4]);
public Native_SetZoneDefaultColor(Handle:plugin, numParams)
{
	new String:sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	
	new iColor[4];
	GetNativeArray(2, iColor, 4);
	
	new group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return false;
	
	Array_Copy(iColor, group[ZG_defaultColor], 4);
	SaveGroup(group);
	
	return true;
}

// native bool:MapZone_SetZoneColor(const String:group[], const String:zoneName[], const iColor[4]);
public Native_SetZoneColor(Handle:plugin, numParams)
{
	new String:sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	new String:sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	new iColor[4];
	GetNativeArray(3, iColor, 4);
	
	// Find a matching cluster or zone.
	new zoneCluster[ZoneCluster], zoneData[ZoneData];
	if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		Array_Copy(iColor, zoneCluster[ZC_color], 4);
		SaveCluster(group, zoneCluster);
		return true;
	}
	else if (GetZoneByName(sZoneName, group, zoneData))
	{
		Array_Copy(iColor, zoneData[ZD_color], 4);
		SaveZone(group, zoneData);
		return true;
	}
		
	return false;
}

// native bool:MapZone_SetClientZoneVisibility(const String:group[], const String:zoneName[], client, bool bVisible);
public Native_SetClientZoneVisibility(Handle:plugin, numParams)
{
	new String:sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	new String:sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	new client = GetNativeCell(3);
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
		return false;
	}
	
	new bool:bVisible = bool:GetNativeCell(4);
	
	// Find a matching cluster or zone.
	new zoneCluster[ZoneCluster], zoneData[ZoneData];
	if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		zoneCluster[ZC_adminShowZones][client] = bVisible;
		SaveCluster(group, zoneCluster);
		
		// Set all zones of this cluster to the same state.
		new iNumZones = GetArraySize(group[ZG_zones]);
		for(new i=0;i<iNumZones;i++)
		{
			GetZoneByIndex(i, group, zoneData);
			if(zoneData[ZD_deleted])
				continue;
			
			if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
				continue;
			
			zoneData[ZD_adminShowZone][client] = bVisible;
			SaveZone(group, zoneData);
		}
		
		return true;
	}
	else if (GetZoneByName(sZoneName, group, zoneData))
	{
		zoneData[ZD_adminShowZone][client] = bVisible;
		SaveZone(group, zoneData);
		return true;
	}
		
	return false;
}

// native bool:MapZone_SetMenuBackAction(const String:group[], MapZoneMenuBackCB:callback);
public Native_SetMenuBackAction(Handle:plugin, numParams)
{
	new String:sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	
#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 7
	new MapZoneMenuBackCB:callback = MapZoneMenuBackCB:GetNativeFunction(2);
#else
	new MapZoneMenuBackCB:callback = MapZoneMenuBackCB:GetNativeCell(2);
#endif
	
	new group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return false;
	
	// Someone registered a menu back action before. Overwrite it.
	if(group[ZG_menuBackForward] != INVALID_HANDLE)
		// Private forwards don't allow to just clear all functions from the list. You HAVE to give the plugin handle -.-
		CloseHandle(group[ZG_menuBackForward]);
	
	group[ZG_menuBackForward] = CreateForward(ET_Ignore, Param_Cell, Param_String);
	AddToForward(group[ZG_menuBackForward], plugin, callback);
	SaveGroup(group);
	
	return true;
}

// native Handle:MapZone_GetGroupZones(const String:group[], bool:bIncludeClusters=true);
public Native_GetGroupZones(Handle:plugin, numParams)
{
	new String:sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	
	new bool:bIncludeClusters = bool:GetNativeCell(2);
	
	new group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return _:INVALID_HANDLE;
	
	new Handle:hZones = CreateArray(ByteCountToCells(MAX_ZONE_NAME));
	// Push all regular zone names
	new iSize = GetArraySize(group[ZG_zones]);
	new zoneData[ZoneData];
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		// NOT in a cluster!
		if(zoneData[ZD_clusterIndex] != -1)
			continue;
		
		PushArrayArray(hZones, _:zoneData[ZD_name], ByteCountToCells(MAX_ZONE_NAME));
	}
	
	// Only add clusters, if we're told so.
	if(bIncludeClusters)
	{
		// And all clusters
		new zoneCluster[ZoneCluster];
		iSize = GetArraySize(group[ZG_cluster]);
		for(new i=0;i<iSize;i++)
		{
			GetZoneClusterByIndex(i, group, zoneCluster);
			if(zoneCluster[ZC_deleted])
				continue;
			
			PushArrayArray(hZones, _:zoneCluster[ZC_name], ByteCountToCells(MAX_ZONE_NAME));
		}
	}
	
	new Handle:hReturn = CloneHandle(hZones, plugin);
	CloseHandle(hZones);
	
	return _:hReturn;
}

// native bool:MapZone_IsClusteredZone(const String:group[], const String:zoneName[]);
public Native_IsClusteredZone(Handle:plugin, numParams)
{
	new String:sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	new String:sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	if(ClusterExistsWithName(group, sZoneName))
		return true;
	
	return false;
}

// native Handle:MapZone_GetClusterZones(const String:group[], const String:clusterName[]);
public Native_GetClusterZones(Handle:plugin, numParams)
{
	new String:sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	new String:sClusterName[MAX_ZONE_NAME];
	GetNativeString(2, sClusterName, sizeof(sClusterName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return _:INVALID_HANDLE;
	
	new zoneCluster[ZoneCluster];
	if(!GetZoneClusterByName(sClusterName, group, zoneCluster))
		return _:INVALID_HANDLE;
	
	new Handle:hZones = CreateArray(ByteCountToCells(MAX_ZONE_NAME));
	// Push all names of zones in this cluster
	new iSize = GetArraySize(group[ZG_zones]);
	new zoneData[ZoneData];
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		// In this cluster?
		if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
			continue;
		
		PushArrayArray(hZones, _:zoneData[ZD_name], ByteCountToCells(MAX_ZONE_NAME));
	}
	
	new Handle:hReturn = CloneHandle(hZones, plugin);
	CloseHandle(hZones);
	
	return _:hReturn;
}

// native bool:MapZone_GetCustomString(const String:group[], const String:zoneName[], const String:key[], String:value[], maxlen);
public Native_GetCustomString(Handle:plugin, numParams)
{
	new String:sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	new String:sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	// Find a matching cluster or zone.
	new zoneCluster[ZoneCluster], zoneData[ZoneData];
	new Handle:hCustomKV;
	if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		hCustomKV = zoneCluster[ZC_customKV];
	}
	else if (GetZoneByName(sZoneName, group, zoneData))
	{
		hCustomKV = zoneData[ZD_customKV];
	}
	
	// No zone/cluster with this name or no custom key values set.
	if (!hCustomKV)
		return false;
	
	new String:sKey[128];
	GetNativeString(3, sKey, sizeof(sKey));
	new maxlen = GetNativeCell(5);
	
	new String:sValue[maxlen];
	if (!GetTrieString(hCustomKV, sKey, sValue, maxlen))
		return false;
	
	SetNativeString(4, sValue, maxlen);
	
	return true;
}

// native bool:MapZone_SetCustomString(const String:group[], const String:zoneName[], const String:key[], const String:value[]);
public Native_SetCustomString(Handle:plugin, numParams)
{
	new String:sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	new String:sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	// Find a matching cluster or zone.
	new zoneCluster[ZoneCluster], zoneData[ZoneData];
	new Handle:hCustomKV;
	if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		if (!zoneCluster[ZC_customKV])
		{
			zoneCluster[ZC_customKV] = CreateTrie();
			SaveCluster(group, zoneCluster);
		}
		hCustomKV = zoneCluster[ZC_customKV];
	}
	else if (GetZoneByName(sZoneName, group, zoneData))
	{
		if (!zoneData[ZD_customKV])
		{
			zoneData[ZD_customKV] = CreateTrie();
			SaveZone(group, zoneData);
		}
		hCustomKV = zoneData[ZD_customKV];
	}
	
	// No zone/cluster with this name
	if (!hCustomKV)
		return false;
	
	new String:sKey[128], String:sValue[256];
	GetNativeString(3, sKey, sizeof(sKey));
	GetNativeString(4, sValue, sizeof(sValue));
	
	// Don't save empty values. Just remove the key then.
	if (sValue[0] == '\0')
		return RemoveFromTrie(hCustomKV, sKey);

	return SetTrieString(hCustomKV, sKey, sValue);
}

/**
 * Entity output handler
 */
public EntOut_OnTouchEvent(const String:output[], caller, activator, Float:delay)
{
	// Ignore invalid touches
	if(activator < 1 || activator > MaxClients)
		return;

	// Get the targetname
	decl String:sTargetName[64];
	GetEntPropString(caller, Prop_Data, "m_iName", sTargetName, sizeof(sTargetName));
	
	new iGroupIndex, iZoneIndex;
	if(!ExtractIndicesFromString(sTargetName, iGroupIndex, iZoneIndex))
		return;
	
	// This zone shouldn't exist!
	if(iGroupIndex >= GetArraySize(g_hZoneGroups))
	{
		AcceptEntityInput(caller, "Kill");
		return;
	}
	
	new group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(iGroupIndex, group);
	
	if(iZoneIndex >= GetArraySize(group[ZG_zones]))
	{
		AcceptEntityInput(caller, "Kill");
		return;
	}
	
	GetZoneByIndex(iZoneIndex, group, zoneData);
	
	// This is an old trigger?
	if(EntRefToEntIndex(zoneData[ZD_triggerEntity]) != caller)
	{
		AcceptEntityInput(caller, "Kill");
		return;
	}
	
	new bool:bEnteredZone = StrEqual(output, "OnStartTouch") || StrEqual(output, "OnTrigger");
	
	// Remember this player interacted with this zone.
	// IT'S IMPORTANT TO MAKE SURE WE REALLY CALL OnEndTouch ON ALL POSSIBLE EVENTS.
	if(bEnteredZone)
	{
		// He already is in this zone? Don't fire the callback twice.
		if(zoneData[ZD_clientInZone][activator])
			return;
		zoneData[ZD_clientInZone][activator] = true;
	}
	else
	{
		// He wasn't in the zone already? Don't fire the callback twice.
		if(!zoneData[ZD_clientInZone][activator])
			return;
		zoneData[ZD_clientInZone][activator] = false;
	}
	SaveZone(group, zoneData);
	
	// Is this zone part of a cluster?
	new String:sZoneName[MAX_ZONE_NAME];
	strcopy(sZoneName, sizeof(sZoneName), zoneData[ZD_name]);
	if(zoneData[ZD_clusterIndex] != -1)
	{
		new zoneCluster[ZoneCluster];
		GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
		
		new bool:bFireForward;
		
		// Player entered a zone of this cluster.
		if(bEnteredZone)
		{
			// This is the first zone of the cluster he enters.
			// Fire the forward with the cluster name instead of the zone name.
			if(zoneCluster[ZC_clientInZones][activator] == 0)
			{
				strcopy(sZoneName, sizeof(sZoneName), zoneCluster[ZC_name]);
				bFireForward = true;
			}
			
			zoneCluster[ZC_clientInZones][activator]++;
		}
		else
		{
			// This is the last zone of the cluster this player leaves.
			// He's no longer in any zone of the cluster, so fire the forward
			// with the cluster name instead of the zone name.
			if(zoneCluster[ZC_clientInZones][activator] == 1)
			{
				strcopy(sZoneName, sizeof(sZoneName), zoneCluster[ZC_name]);
				bFireForward = true;
			}
			zoneCluster[ZC_clientInZones][activator]--;
		}
		
		// Uhm.. are you alright, engine?
		if(zoneCluster[ZC_clientInZones][activator] < 0)
			zoneCluster[ZC_clientInZones][activator] = 0;
		
		SaveCluster(group, zoneCluster);
		
		// This client is in more than one zone of the cluster. Don't fire the forward.
		if(!bFireForward)
			return;
	}
	
	// Inform other plugins, that someone entered or left this zone/cluster.
	if(bEnteredZone)
		Call_StartForward(g_hfwdOnEnterForward);
	else
		Call_StartForward(g_hfwdOnLeaveForward);
	Call_PushCell(activator);
	Call_PushString(group[ZG_name]);
	Call_PushString(sZoneName);
	Call_Finish();
}

/**
 * Timer callbacks
 */
public Action:Timer_ShowZones(Handle:timer)
{
	new Float:fDistanceLimit = GetConVarFloat(g_hCVDebugBeamDistance);

	new iNumGroups = GetArraySize(g_hZoneGroups);
	new group[ZoneGroup], zoneCluster[ZoneCluster], zoneData[ZoneData], iNumZones;
	new Float:fPos[3], Float:fMins[3], Float:fMaxs[3], Float:fAngles[3];
	new iClients[MaxClients], iNumClients;
	new iDefaultColor[4], iColor[4];
	
	new bool:bOptimizeBeams = GetConVarBool(g_hCVOptimizeBeams);
	
	new Float:vFirstPoint[3], Float:vSecondPoint[3];
	new Float:fClientAngles[3], Float:fClientEyePosition[3], Float:fClientToZonePoint[3], Float:fLength;
	for(new i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		
		Array_Copy(group[ZG_defaultColor], iDefaultColor, 4);
		iNumZones = GetArraySize(group[ZG_zones]);
		for(new z=0;z<iNumZones;z++)
		{
			GetZoneByIndex(z, group, zoneData);
			if(zoneData[ZD_deleted])
				continue;
			
			Array_Copy(zoneData[ZD_position], fPos, 3);
			Array_Copy(zoneData[ZD_mins], fMins, 3);
			Array_Copy(zoneData[ZD_maxs], fMaxs, 3);
			Array_Copy(zoneData[ZD_rotation], fAngles, 3);
			
			// Fetch cluster if zone is in one for the color.
			zoneCluster[ZC_color][0] = -1;
			if (zoneData[ZD_clusterIndex] != -1)
				GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
			
			// Use the custom color of the cluster if set.
			if (zoneCluster[ZC_color][0] >= 0)
			{
				Array_Copy(zoneCluster[ZC_color], iColor, 4);
			}
			// Use the custom color of the zone if set.
			else if (zoneData[ZD_color][0] >= 0)
			{
				Array_Copy(zoneData[ZD_color], iColor, 4);
			}
			// Use the default color of the group, if not overwritten.
			else
			{
				Array_Copy(iDefaultColor, iColor, 4);
			}
			
			// Get the world coordinates of the corners to check if players could see them.
			if(bOptimizeBeams)
			{
				Math_RotateVector(fMins, fAngles, vFirstPoint);
				AddVectors(vFirstPoint, fPos, vFirstPoint);
				Math_RotateVector(fMaxs, fAngles, vSecondPoint);
				AddVectors(vSecondPoint, fPos, vSecondPoint);
			}
			
			iNumClients = 0;
			for(new c=1;c<=MaxClients;c++)
			{
				if(!IsClientInGame(c) || IsFakeClient(c))
					continue;
				
				if(!group[ZG_showZones] && !zoneData[ZD_adminShowZone][c])
					continue;
				
				// Could the player see the zone?
				if(bOptimizeBeams)
				{
					GetClientEyeAngles(c, fClientAngles);
					GetAngleVectors(fClientAngles, fClientAngles, NULL_VECTOR, NULL_VECTOR);
					NormalizeVector(fClientAngles, fClientAngles);
					GetClientEyePosition(c, fClientEyePosition);
					
					// TODO: Consider player FOV!
					// See if the first corner of the zone is in front of the player and near enough.
					MakeVectorFromPoints(fClientEyePosition, vFirstPoint, fClientToZonePoint);
					fLength = FloatAbs(GetVectorLength(fClientToZonePoint));
					NormalizeVector(fClientToZonePoint, fClientToZonePoint);
					if(GetVectorDotProduct(fClientAngles, fClientToZonePoint) < 0 || fLength > fDistanceLimit)
					{
						// First corner is behind the player or too far away..
						// See if the second corner is in front of the player.
						MakeVectorFromPoints(fClientEyePosition, vSecondPoint, fClientToZonePoint);
						fLength = FloatAbs(GetVectorLength(fClientToZonePoint));
						NormalizeVector(fClientToZonePoint, fClientToZonePoint);
						if(GetVectorDotProduct(fClientAngles, fClientToZonePoint) < 0 || fLength > fDistanceLimit)
						{
							// Second corner is behind the player or too far away..
							// See if the center is in front of the player.
							MakeVectorFromPoints(fClientEyePosition, fPos, fClientToZonePoint);
							fLength = FloatAbs(GetVectorLength(fClientToZonePoint));
							NormalizeVector(fClientToZonePoint, fClientToZonePoint);
							if(GetVectorDotProduct(fClientAngles, fClientToZonePoint) < 0 || fLength > fDistanceLimit)
							{
								// The zone is completely behind the player. Don't send it to him.
								continue;
							}
						}
					}
				}
				
				// Player wants to see this individual zone or admin enabled showing of all zones to all players.
				iClients[iNumClients++] = c;
			}
			
			if(iNumClients > 0)
				Effect_DrawBeamBoxRotatable(iClients, iNumClients, fPos, fMins, fMaxs, fAngles, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 5.0, 5.0, 2, 1.0, iColor, 5);
		}
	}
	
	
	for(new i=1;i<=MaxClients;i++)
	{
		if(g_ClientMenuState[i][CMS_editPosition]
		|| g_ClientMenuState[i][CMS_editRotation]
		|| g_ClientMenuState[i][CMS_editCenter])
		{
			// Currently pasting a zone. Wait until user gives a name before showing anything.
			if(g_ClientMenuState[i][CMS_zone] == -1 && g_ClientMenuState[i][CMS_editCenter])
				continue;
				
			GetGroupByIndex(g_ClientMenuState[i][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[i][CMS_zone], group, zoneData);
			
			// Only change the center of the zone. Don't touch other parameters.
			if(g_ClientMenuState[i][CMS_editCenter])
			{
				Array_Copy(g_ClientMenuState[i][CMS_center], fPos, 3);
				Array_Copy(zoneData[ZD_rotation], fAngles, 3);
			}
			else
			{
				Array_Copy(zoneData[ZD_position], fPos, 3);
				Array_Copy(g_ClientMenuState[i][CMS_rotation], fAngles, 3);
			}
			
			// Get the bounds and only have the rotation changable.
			if(g_ClientMenuState[i][CMS_editRotation]
			|| g_ClientMenuState[i][CMS_editCenter])
			{
				Array_Copy(zoneData[ZD_mins], fMins, 3);
				Array_Copy(zoneData[ZD_maxs], fMaxs, 3);
			}
			// Highlight the corner he's editing.
			else if(g_ClientMenuState[i][CMS_editPosition])
			{
				Array_Copy(g_ClientMenuState[i][CMS_first], vFirstPoint, 3);
				Array_Copy(g_ClientMenuState[i][CMS_second], vSecondPoint, 3);
				
				SubtractVectors(vFirstPoint, fPos, fMins);
				SubtractVectors(vSecondPoint, fPos, fMaxs);
				
				if(g_ClientMenuState[i][CMS_editState] == ZES_first)
				{
					Math_RotateVector(fMins, fAngles, vFirstPoint);
					AddVectors(vFirstPoint, fPos, vFirstPoint);
					TE_SetupGlowSprite(vFirstPoint, g_iGlowSprite, 2.0, 1.0, 100);
				}
				else
				{
					Math_RotateVector(fMaxs, fAngles, vSecondPoint);
					AddVectors(vSecondPoint, fPos, vSecondPoint);
					TE_SetupGlowSprite(vSecondPoint, g_iGlowSprite, 2.0, 1.0, 100);
				}
				TE_SendToClient(i);
			}
			
			// Draw the zone
			Effect_DrawBeamBoxRotatableToClient(i, fPos, fMins, fMaxs, fAngles, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 5.0, 5.0, 2, 1.0, {0,0,255,255}, 0);
			Effect_DrawAxisOfRotationToClient(i, fPos, fAngles, Float:{10.0,10.0,10.0}, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 5.0, 5.0, 2, 1.0, 0);
		}
	}
	
	return Plugin_Continue;
}

public Action:Timer_ShowZoneWhileAdding(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (!client)
		return Plugin_Stop;
	
	// Don't show temporary stuff anymore when done with both corners.
	if(g_ClientMenuState[client][CMS_editState] == ZES_name)
	{
		// Keep drawing the new zone while he enters a name for it.
		if (g_ClientMenuState[client][CMS_addZone])
		{
			new Float:fFirstPoint[3], Float:fSecondPoint[3];
			Array_Copy(g_ClientMenuState[client][CMS_first], fFirstPoint, 3);
			Array_Copy(g_ClientMenuState[client][CMS_second], fSecondPoint, 3);
			
			Effect_DrawBeamBoxToClient(client, fFirstPoint, fSecondPoint, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 5.0, 5.0, 2, 1.0, {0,0,255,255}, 0);
		}
		return Plugin_Continue;
	}
	
	// Don't show anything when preview is disabled.
	if(g_ClientMenuState[client][CMS_disablePreview])
		return Plugin_Continue;
	
	// Get the client's aim position.
	new Float:fAimPosition[3], Float:fUnsnappedAimPosition[3];
	if (!GetClientZoneAimPosition(client, fAimPosition, fUnsnappedAimPosition))
		return Plugin_Continue;
	
	// Show an indicator on where the client aims at.
	if (g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
	{
		TE_SetupGlowSprite(fAimPosition, g_iGlowSprite, 0.1, 0.1, 150);
		TE_SendToClient(client);
	}
	
	// Get the snapped and unsnapped target positions now.
	// Unsnapped, so we can draw a line between the points to show the user where it'll snap to.
	new Float:fTargetPosition[3], Float:fUnsnappedTargetPosition[3];
	if (g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
	{
		fTargetPosition = fAimPosition;
		fUnsnappedTargetPosition = fUnsnappedAimPosition;
	}
	else
	{
		new Float:fGroundNormal[3];
		GetClientFeetPosition(client, fUnsnappedTargetPosition, fGroundNormal);
		SnapToGrid(client, fUnsnappedTargetPosition, fTargetPosition, fGroundNormal);
		
		TE_SetupGlowSprite(fTargetPosition, g_iGlowSprite, 0.1, 0.7, 150);
		TE_SendToClient(client);
		
		// Put the start position a little bit higher and behind the player.
		// That way you still see the beam, even if it's right below you.
		fUnsnappedTargetPosition[2] += 32.0;
		new Float:fViewDirection[3];
		GetClientEyeAngles(client, fViewDirection);
		fViewDirection[0] = 0.0; // Ignore up/down view.
		GetAngleVectors(fViewDirection, fViewDirection, NULL_VECTOR, NULL_VECTOR);
		ScaleVector(fViewDirection, -16.0);
		AddVectors(fUnsnappedTargetPosition, fViewDirection, fUnsnappedTargetPosition);
	}
	
	// Show a beam from player position to snapped grid corner.
	if ((g_ClientMenuState[client][CMS_snapToGrid] || g_ClientMenuState[client][CMS_previewMode] == ZPM_feet)
	&& IsClientEditingZonePosition(client))
		ShowGridSnapBeamToClient(client, fUnsnappedTargetPosition, fTargetPosition);
	
	// Preview the zone in realtime while editing.
	if (g_ClientMenuState[client][CMS_editCenter]
	|| g_ClientMenuState[client][CMS_editPosition]
	|| g_ClientMenuState[client][CMS_editState] == ZES_second)
	{
		// When editing the center, we can display the rotation too :)
		if (g_ClientMenuState[client][CMS_editCenter])
		{
			new group[ZoneGroup], zoneData[ZoneData];
			GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
			
			// Only change the center of the box, keep all the other paramters the same.
			new Float:fCenter[3], Float:fRotation[3], Float:fMins[3], Float:fMaxs[3];
			fCenter = fTargetPosition;
			Array_Copy(zoneData[ZD_rotation], fRotation, 3);
			Array_Copy(zoneData[ZD_mins], fMins, 3);
			Array_Copy(zoneData[ZD_maxs], fMaxs, 3);
			
			Effect_DrawBeamBoxRotatableToClient(client, fCenter, fMins, fMaxs, fRotation, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 5.0, 5.0, 2, 1.0, {0,0,255,255}, 0);
			return Plugin_Continue;
		}
		
		new Float:fFirstPoint[3], Float:fSecondPoint[3];
		// Copy the right other coordinate from the zone over.
		if (g_ClientMenuState[client][CMS_editState] == ZES_first)
		{
			fFirstPoint = fTargetPosition;
			
			Array_Copy(g_ClientMenuState[client][CMS_second], fSecondPoint, 3);
			HandleZoneDefaultHeight(fFirstPoint[2], fSecondPoint[2]);
		}
		else
		{
			Array_Copy(g_ClientMenuState[client][CMS_first], fFirstPoint, 3);
			fSecondPoint = fTargetPosition;
			
			HandleZoneDefaultHeight(fFirstPoint[2], fSecondPoint[2]);
		}
		
		// TODO: When editing a zone, apply the rotation again.
		Effect_DrawBeamBoxToClient(client, fFirstPoint, fSecondPoint, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 5.0, 5.0, 2, 1.0, {0,0,255,255}, 0);
	}
	
	return Plugin_Continue;
}

ShowGridSnapBeamToClient(client, Float:fFirstPoint[3], Float:fSecondPoint[3])
{
	TE_SetupBeamPoints(fFirstPoint, fSecondPoint, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 1.0, 1.0, 2, 1.0, {0,255,0,255}, 0);
	TE_SendToClient(client);
}

/**
 * Menu stuff
 */
DisplayGroupRootMenu(client, group[ZoneGroup])
{
	// Can't browse the zones (and possibly change the selected group in the client menu state)
	// while adding a zone.
	if(g_ClientMenuState[client][CMS_addZone])
	{
		ResetZoneAddingState(client);
		PrintToChat(client, "Map Zones > Aborted adding of zone.");
	}
	
	if(g_ClientMenuState[client][CMS_addCluster])
	{
		g_ClientMenuState[client][CMS_addCluster] = false;
		PrintToChat(client, "Map Zones > Aborted adding of cluster.");
	}
	
	g_ClientMenuState[client][CMS_editCenter] = false;
	g_ClientMenuState[client][CMS_editRotation] = false;
	g_ClientMenuState[client][CMS_cluster] = -1;
	g_ClientMenuState[client][CMS_zone] = -1;

	new Handle:hMenu = CreateMenu(Menu_HandleGroupRoot);
	SetMenuTitle(hMenu, "Manage zone group \"%s\"", group[ZG_name]);
	SetMenuExitButton(hMenu, true);
	if(group[ZG_menuBackForward] != INVALID_HANDLE)
		SetMenuExitBackButton(hMenu, true);
	
	new String:sBuffer[64];
	AddMenuItem(hMenu, "add", "Add new zone");
	AddMenuItem(hMenu, "paste", "Paste zone from clipboard", (HasZoneInClipboard(client)?ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED));
	Format(sBuffer, sizeof(sBuffer), "Show Zones to all: %T", (group[ZG_showZones]?"Yes":"No"), client);
	AddMenuItem(hMenu, "showzonesall", sBuffer);
	Format(sBuffer, sizeof(sBuffer), "Show Zones to me only: %T\n \n", (group[ZG_adminShowZones][client]?"Yes":"No"), client);
	AddMenuItem(hMenu, "showzonesme", sBuffer);
	
	// Show zone count
	new iNumZones, zoneData[ZoneData];
	new iSize =GetArraySize(group[ZG_zones]);
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		if(zoneData[ZD_clusterIndex] != -1)
			continue;
		iNumZones++;
	}
	Format(sBuffer, sizeof(sBuffer), "List standalone zones (%d)", iNumZones);
	AddMenuItem(hMenu, "zones", sBuffer);
	
	// Show cluster count
	new iNumClusters, zoneCluster[ZoneCluster];
	iSize = GetArraySize(group[ZG_cluster]);
	for(new i=0;i<iSize;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		if(zoneCluster[ZC_deleted])
			continue;
		iNumClusters++;
	}
	Format(sBuffer, sizeof(sBuffer), "List zone clusters (%d)", iNumClusters);
	AddMenuItem(hMenu, "clusters", sBuffer);
	
	g_ClientMenuState[client][CMS_group] = group[ZG_index];
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
	
	// We might have interrupted one of our own menus which cancelled and unset our group state :(
	g_ClientMenuState[client][CMS_group] = group[ZG_index];
}

public Menu_HandleGroupRoot(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		// Handle toggling of zone visibility first
		if(StrEqual(sInfo, "showzonesall"))
		{
			// warning 226: a variable is assigned to itself (symbol "group")
			//group[ZG_showZones] = !group[ZG_showZones];
			new bool:swap = group[ZG_showZones];
			group[ZG_showZones] = !swap;
			SaveGroup(group);
			
			// Show zones right away.
			if(group[ZG_showZones])
				TriggerTimer(g_hShowZonesTimer, true);
			DisplayGroupRootMenu(param1, group);
		}
		// Show zone only to menu user.
		else if(StrEqual(sInfo, "showzonesme"))
		{
			// warning 226: a variable is assigned to itself (symbol "group")
			//group[ZG_showZones] = !group[ZG_showZones];
			// We save the toggle state for this menu in the group.
			// The actual showing/hiding of zones is done in the below loop.
			new bool:swap = !group[ZG_adminShowZones][param1];
			group[ZG_adminShowZones][param1] = swap;
			SaveGroup(group);
			
			// Set the zones in this group to show for this admin or not.
			new iNumZones = GetArraySize(group[ZG_zones]);
			new zoneData[ZoneData];
			for(new i=0;i<iNumZones;i++)
			{
				GetZoneByIndex(i, group, zoneData);
				zoneData[ZD_adminShowZone][param1] = swap;
				SaveZone(group, zoneData);
			}
			
			// Remember this setting for contained clusters too.
			new iNumClusters = GetArraySize(group[ZG_cluster]);
			new zoneCluster[ZoneCluster];
			for(new i=0;i<iNumClusters;i++)
			{
				GetZoneClusterByIndex(i, group, zoneCluster);
				zoneCluster[ZC_adminShowZones][param1] = swap;
				SaveCluster(group, zoneCluster);
			}
			
			// Show zones right away.
			if(group[ZG_adminShowZones][param1])
				TriggerTimer(g_hShowZonesTimer, true);
			DisplayGroupRootMenu(param1, group);
		}
		else if(StrEqual(sInfo, "add"))
		{
			g_ClientMenuState[param1][CMS_addZone] = true;
			g_ClientMenuState[param1][CMS_editState] = ZES_first;
			DisplayZonePointEditMenu(param1);
			PrintToChat(param1, "Map Zones > Click on the two points or push \"e\" to set them at your feet, which will specify the two diagonal opposite corners of the zone.");
		}
		// Paste zone from clipboard.
		else if(StrEqual(sInfo, "paste"))
		{
			if(HasZoneInClipboard(param1))
				PasteFromClipboard(param1);
			else
				DisplayGroupRootMenu(param1, group);
		}
		else if(StrEqual(sInfo, "zones"))
		{
			DisplayZoneListMenu(param1);
		}
		else if(StrEqual(sInfo, "clusters"))
		{
			DisplayClusterListMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			new group[ZoneGroup];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			// This group has a menu back action handler registered? Call it!
			if(group[ZG_menuBackForward] != INVALID_HANDLE)
			{
				Call_StartForward(group[ZG_menuBackForward]);
				Call_PushCell(param1);
				Call_PushString(group[ZG_name]);
				Call_Finish();
			}
		}
		g_ClientMenuState[param1][CMS_group] = -1;
	}
}

DisplayZoneListMenu(client)
{
	new group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		
	new Handle:hMenu = CreateMenu(Menu_HandleZoneList);
	if(g_ClientMenuState[client][CMS_cluster] == -1)
	{
		SetMenuTitle(hMenu, "Manage zones for \"%s\"", group[ZG_name]);
	}
	else
	{
		// Reuse this menu to add zones to a cluster form the cluster edit menu directly.
		// It looks the same, is just handled differently.
		new zoneCluster[ZoneCluster];
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
		SetMenuTitle(hMenu, "Add zones to cluster \"%s\"", zoneCluster[ZC_name]);
	}
	SetMenuExitBackButton(hMenu, true);

	AddMenuItem(hMenu, "add", "Add new zone\n \n");

	new String:sBuffer[64];
	new iNumZones = GetArraySize(group[ZG_zones]);
	new zoneData[ZoneData], iZoneCount;
	for(new i=0;i<iNumZones;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		// Ignore zones marked as deleted.
		if(zoneData[ZD_deleted])
			continue;
		
		// Only display zones NOT in a cluster.
		if(zoneData[ZD_clusterIndex] != -1)
			continue;
		
		IntToString(i, sBuffer, sizeof(sBuffer));
		AddMenuItem(hMenu, sBuffer, zoneData[ZD_name]);
		iZoneCount++;
	}
	
	if(!iZoneCount)
	{
		AddMenuItem(hMenu, "", "No zones in this group.", ITEMDRAW_DISABLED);
	}
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleZoneList(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));

		if(StrEqual(sInfo, "add"))
		{
			g_ClientMenuState[param1][CMS_addZone] = true;
			g_ClientMenuState[param1][CMS_editState] = ZES_first;
			DisplayZonePointEditMenu(param1);
			PrintToChat(param1, "Map Zones > Click on the two points or push \"e\" to set them at your feet, which will specify the two diagonal opposite corners of the zone.");
			return;
		}
		
		new iZoneIndex = StringToInt(sInfo);

		// Normal zone list accessed from the main menu.
		if(g_ClientMenuState[param1][CMS_cluster] == -1)
		{
			g_ClientMenuState[param1][CMS_zone] = iZoneIndex;
			DisplayZoneEditMenu(param1);
		}
		// Zone list accessed from the cluster edit menu.
		// Add this zone to the cluster.
		else
		{
			new group[ZoneGroup], zoneCluster[ZoneCluster], zoneData[ZoneData];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			GetZoneClusterByIndex(g_ClientMenuState[param1][CMS_cluster], group, zoneCluster);
			GetZoneByIndex(iZoneIndex, group, zoneData);

			// TODO: Make sure the cluster wasn't deleted while the menu was open.
			// Two admins playing against each other?
			if(zoneData[ZD_deleted])
			{
				PrintToChat(param1, "Map Zones > Can't add zone \"%s\", because it got deleted while the menu was open.", zoneData[ZD_name]);
				DisplayZoneListMenu(param1);
				return;
			}

			// Add the zone to the cluster and display the list right again.
			// TODO: Check if the zone was in a cluster before and evaluate again, if the client is still in the old cluster?
			zoneData[ZD_clusterIndex] = g_ClientMenuState[param1][CMS_cluster];
			SaveZone(group, zoneData);
			PrintToChat(param1, "Map Zones > Added zone \"%s\" to cluster \"%s\" in group \"%s\".", zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
			DisplayZoneListMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			// Not editing a cluster currently.
			// Show the root menu again.
			if(g_ClientMenuState[param1][CMS_cluster] == -1)
			{
				new group[ZoneGroup];
				GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
				DisplayGroupRootMenu(param1, group);
			}
			else
			{
				// We came here from the cluster edit menu. Go back there.
				DisplayClusterEditMenu(param1);
			}
		}
		else
		{
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
		}
	}
}

DisplayClusterListMenu(client)
{
	new group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	
	new Handle:hMenu = CreateMenu(Menu_HandleClusterList);
	SetMenuTitle(hMenu, "Manage clusters for \"%s\"\nZones in a cluster will act like one big zone.\nAllows for different shapes than just rectangles.", group[ZG_name]);
	SetMenuExitBackButton(hMenu, true);

	AddMenuItem(hMenu, "add", "Add cluster\n \n");
	
	new String:sBuffer[64];
	new iNumClusters = GetArraySize(group[ZG_cluster]);
	new zoneCluster[ZoneCluster], iClusterCount;
	for(new i=0;i<iNumClusters;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		// Ignore clusters marked as deleted.
		if(zoneCluster[ZC_deleted])
			continue;
		
		IntToString(i, sBuffer, sizeof(sBuffer));
		AddMenuItem(hMenu, sBuffer, zoneCluster[ZC_name]);
		iClusterCount++;
	}
	
	if(!iClusterCount)
	{
		AddMenuItem(hMenu, "", "No clusters in this group.", ITEMDRAW_DISABLED);
	}
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleClusterList(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		if(StrEqual(sInfo, "add"))
		{
			PrintToChat(param1, "Map Zones > Enter name of new cluster in chat. Type \"!abort\" to abort.");
			g_ClientMenuState[param1][CMS_addCluster] = true;
			return;
		}
		
		new iClusterIndex = StringToInt(sInfo);
		g_ClientMenuState[param1][CMS_cluster] = iClusterIndex;
		DisplayClusterEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			new group[ZoneGroup];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			DisplayGroupRootMenu(param1, group);
		}
		else
		{
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

DisplayClusterEditMenu(client)
{
	new group[ZoneGroup], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);

	if(zoneCluster[ZC_deleted])
	{
		g_ClientMenuState[client][CMS_cluster] = -1;
		DisplayClusterListMenu(client);
		return;
	}
	
	new Handle:hMenu = CreateMenu(Menu_HandleClusterEdit);
	SetMenuExitBackButton(hMenu, true);
	SetMenuTitle(hMenu, "Manage cluster \"%s\" of group \"%s\"", zoneCluster[ZC_name], group[ZG_name]);
	
	new String:sBuffer[64];
	Format(sBuffer, sizeof(sBuffer), "Show zones in this cluster to me: %T", (zoneCluster[ZC_adminShowZones][client]?"Yes":"No"), client);
	AddMenuItem(hMenu, "show", sBuffer);
	AddMenuItem(hMenu, "add", "Add zone to cluster");
	
	new String:sTeam[32] = "Any";
	if(zoneCluster[ZC_teamFilter] > 1)
		GetTeamName(zoneCluster[ZC_teamFilter], sTeam, sizeof(sTeam));
	Format(sBuffer, sizeof(sBuffer), "Team filter: %s", sTeam);
	AddMenuItem(hMenu, "team", sBuffer);
	AddMenuItem(hMenu, "paste", "Paste zone from clipboard", (HasZoneInClipboard(client)?ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED));
	AddMenuItem(hMenu, "rename", "Rename");
	AddMenuItem(hMenu, "delete", "Delete");
	
	AddMenuItem(hMenu, "", "Zones:", ITEMDRAW_DISABLED);
	new iNumZones = GetArraySize(group[ZG_zones]);
	new zoneData[ZoneData], iZoneCount;
	for(new i=0;i<iNumZones;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		// Ignore zones marked as deleted.
		if(zoneData[ZD_deleted])
			continue;
		
		// Only display zones NOT in a cluster.
		if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
			continue;
		
		IntToString(i, sBuffer, sizeof(sBuffer));
		AddMenuItem(hMenu, sBuffer, zoneData[ZD_name]);
		iZoneCount++;
	}
	
	if(!iZoneCount)
	{
		AddMenuItem(hMenu, "", "No zones in this cluster.", ITEMDRAW_DISABLED);
	}
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleClusterEdit(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup], zoneCluster[ZoneCluster];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneClusterByIndex(g_ClientMenuState[param1][CMS_cluster], group, zoneCluster);
		
		// Add new zone in the cluster
		if(StrEqual(sInfo, "add"))
		{
			DisplayZoneListMenu(param1);
		}
		// Show all zones in this cluster to one admin
		else if(StrEqual(sInfo, "show"))
		{
			new bool:swap = !zoneCluster[ZC_adminShowZones][param1];
			zoneCluster[ZC_adminShowZones][param1] = swap;
			SaveCluster(group, zoneCluster);
			
			// Set all zones of this cluster to the same state.
			new iNumZones = GetArraySize(group[ZG_zones]);
			new zoneData[ZoneData];
			for(new i=0;i<iNumZones;i++)
			{
				GetZoneByIndex(i, group, zoneData);
				if(zoneData[ZD_deleted])
					continue;
				
				if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
					continue;
				
				zoneData[ZD_adminShowZone][param1] = swap;
				SaveZone(group, zoneData);
			}
			
			// Show zones right away.
			if(zoneCluster[ZC_adminShowZones][param1])
				TriggerTimer(g_hShowZonesTimer, true);
			
			DisplayClusterEditMenu(param1);
		}
		// Toggle team restriction for this cluster
		else if(StrEqual(sInfo, "team"))
		{
			// Loop through all teams
			new iTeam = zoneCluster[ZC_teamFilter];
			iTeam++;
			// Start from the beginning
			if(iTeam > 3)
				iTeam = 0;
			// Skip "spectator"
			else if(iTeam == 1)
				iTeam = 2;
			zoneCluster[ZC_teamFilter] = iTeam;
			SaveCluster(group, zoneCluster);
			
			// Set all zones of this cluster to the same state.
			new iNumZones = GetArraySize(group[ZG_zones]);
			new zoneData[ZoneData];
			for(new i=0;i<iNumZones;i++)
			{
				GetZoneByIndex(i, group, zoneData);
				if(zoneData[ZD_deleted])
					continue;
				
				if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
					continue;
				
				zoneData[ZD_teamFilter] = iTeam;
				SaveZone(group, zoneData);
				ApplyTeamRestrictionFilter(group, zoneData);
			}
			
			DisplayClusterEditMenu(param1);
		}
		// Paste zone from clipboard.
		else if(StrEqual(sInfo, "paste"))
		{
			if(HasZoneInClipboard(param1))
				PasteFromClipboard(param1);
			else
				DisplayClusterEditMenu(param1);
		}
		// Change the name of the cluster
		else if(StrEqual(sInfo, "rename"))
		{
			PrintToChat(param1, "Map Zones > Type new name in chat for cluster \"%s\" or \"!abort\" to cancel renaming.", zoneCluster[ZC_name]);
			g_ClientMenuState[param1][CMS_rename] = true;
		}
		// Delete the cluster
		else if(StrEqual(sInfo, "delete"))
		{
			decl String:sBuffer[128];
			new Handle:hPanel = CreatePanel();
			Format(sBuffer, sizeof(sBuffer), "Do you really want to delete cluster \"%s\"?", zoneCluster[ZC_name]);
			SetPanelTitle(hPanel, sBuffer);
			
			DrawPanelItem(hPanel, "Yes, delete cluster and all contained zones");
			DrawPanelItem(hPanel, "Yes, delete cluster, but keep all contained zones");
			DrawPanelItem(hPanel, "No, DON'T delete anything");
			
			SendPanelToClient(hPanel, param1, Panel_HandleConfirmDeleteCluster, MENU_TIME_FOREVER);
			CloseHandle(hPanel);
		}
		else
		{
			new iZoneIndex = StringToInt(sInfo);
			g_ClientMenuState[param1][CMS_zone] = iZoneIndex;
			DisplayZoneEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_cluster] = -1;
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayClusterListMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

public Panel_HandleConfirmDeleteCluster(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_Select)
	{
		// Selected "No", go back.
		if(param2 > 2)
		{
			DisplayClusterEditMenu(param1);
			return;
		}
		
		new group[ZoneGroup], zoneCluster[ZoneCluster];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneClusterByIndex(g_ClientMenuState[param1][CMS_cluster], group, zoneCluster);
		
		// We can't really delete it, because the array indicies would shift. Just don't save it to file and skip it.
		zoneCluster[ZC_deleted] = true;
		SaveCluster(group, zoneCluster);
		
		// Delete all contained zones in the cluster too.
		// Make sure the trigger is removed.
		new iNumZones = GetArraySize(group[ZG_zones]);
		new zoneData[ZoneData];
		new iZonesCount;
		for(new i=0;i<iNumZones;i++)
		{
			GetZoneByIndex(i, group, zoneData);
			if(zoneData[ZD_deleted])
				continue;
			
			// Only delete zones in this cluster!
			if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
				continue;
			
			// Want to delete the zones in the cluster too?
			if(param2 == 1)
			{
				RemoveZoneTrigger(group, zoneData);
				zoneData[ZD_deleted] = true;
			}
			// Just remove the zone from the cluster, but keep it.
			else
			{
				zoneData[ZD_clusterIndex] = -1;
			}
			SaveZone(group, zoneData);
			iZonesCount++;
		}
		
		g_ClientMenuState[param1][CMS_cluster] = -1;
		DisplayClusterListMenu(param1);
		
		if(param2 == 1)
			LogAction(param1, -1, "%L deleted cluster \"%s\" and %d contained zones from group \"%s\".", param1, zoneCluster[ZC_name], iZonesCount, group[ZG_name]);
		else
			LogAction(param1, -1, "%L deleted cluster \"%s\" from group \"%s\", but kept %d contained zones.", param1, zoneCluster[ZC_name], group[ZG_name], iZonesCount);
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_group] = -1;
		g_ClientMenuState[param1][CMS_cluster] = -1;
	}
}

DisplayZoneEditMenu(client)
{
	new group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);

	if(zoneData[ZD_deleted])
	{
		DisplayGroupRootMenu(client, group);
		return;
	}
	
	new Handle:hMenu = CreateMenu(Menu_HandleZoneEdit);
	SetMenuExitBackButton(hMenu, true);
	if(zoneData[ZD_clusterIndex] == -1)
		SetMenuTitle(hMenu, "Manage zone \"%s\" in group \"%s\"", zoneData[ZD_name], group[ZG_name]);
	else
	{
		GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
		SetMenuTitle(hMenu, "Manage zone \"%s\" in cluster \"%s\" of group \"%s\"", zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
	}
	
	new String:sBuffer[128];
	AddMenuItem(hMenu, "teleport", "Teleport to");
	Format(sBuffer, sizeof(sBuffer), "Show zone to me: %T", (zoneData[ZD_adminShowZone][client]?"Yes":"No"), client);
	AddMenuItem(hMenu, "show", sBuffer);
	AddMenuItem(hMenu, "edit", "Edit zone");
	
	new String:sTeam[32] = "Any";
	if(zoneData[ZD_teamFilter] > 1)
		GetTeamName(zoneData[ZD_teamFilter], sTeam, sizeof(sTeam));
	Format(sBuffer, sizeof(sBuffer), "Team filter: %s", sTeam);
	AddMenuItem(hMenu, "team", sBuffer);
	
	if(zoneData[ZD_clusterIndex] == -1)
		Format(sBuffer, sizeof(sBuffer), "Add to a cluster");
	else
		Format(sBuffer, sizeof(sBuffer), "Remove from cluster \"%s\"", zoneCluster[ZC_name]);
	AddMenuItem(hMenu, "cluster", sBuffer);
	AddMenuItem(hMenu, "copy", "Copy to clipboard");
	AddMenuItem(hMenu, "rename", "Rename");
	AddMenuItem(hMenu, "delete", "Delete");
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleZoneEdit(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup], zoneData[ZoneData];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		// Teleport to the zone
		if(StrEqual(sInfo, "teleport"))
		{
			new Float:vBuf[3];
			Array_Copy(zoneData[ZD_position], vBuf, 3);
			TeleportEntity(param1, vBuf, NULL_VECTOR, NULL_VECTOR);
			DisplayZoneEditMenu(param1);
		}
		// Show zone to admin
		else if(StrEqual(sInfo, "show"))
		{
			new bool:swap = !zoneData[ZD_adminShowZone][param1];
			zoneData[ZD_adminShowZone][param1] = swap;
			SaveZone(group, zoneData);
			
			if(zoneData[ZD_adminShowZone][param1])
				TriggerTimer(g_hShowZonesTimer, true);
			DisplayZoneEditMenu(param1);
		}
		// Edit details like position and rotation
		else if(!StrContains(sInfo, "edit"))
		{
			DisplayZoneEditDetailsMenu(param1);
		}
		// Toggle team restriction for this zone
		else if(StrEqual(sInfo, "team"))
		{
			// Loop through all teams
			new iTeam = zoneData[ZD_teamFilter];
			iTeam++;
			// Start from the beginning
			if(iTeam > 3)
				iTeam = 0;
			// Skip "spectator"
			else if(iTeam == 1)
				iTeam = 2;
			zoneData[ZD_teamFilter] = iTeam;
			SaveZone(group, zoneData);
			ApplyTeamRestrictionFilter(group, zoneData);
			
			DisplayZoneEditMenu(param1);
		}
		// Change the name of the zone
		else if(StrEqual(sInfo, "cluster"))
		{
			// Not in a cluster.
			if(zoneData[ZD_clusterIndex] == -1)
			{
				DisplayClusterSelectionMenu(param1);
			}
			// Zone is part of a cluster
			else
			{
				new zoneCluster[ZoneCluster];
				GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
			
				decl String:sBuffer[128];
				new Handle:hPanel = CreatePanel();
				Format(sBuffer, sizeof(sBuffer), "Do you really want to remove zone \"%s\" from cluster \"%s\"?", zoneData[ZD_name], zoneCluster[ZC_name]);
				SetPanelTitle(hPanel, sBuffer);
				
				Format(sBuffer, sizeof(sBuffer), "%T", "Yes", param1);
				DrawPanelItem(hPanel, sBuffer);
				Format(sBuffer, sizeof(sBuffer), "%T", "No", param1);
				DrawPanelItem(hPanel, sBuffer);
				
				SendPanelToClient(hPanel, param1, Panel_HandleConfirmRemoveFromCluster, MENU_TIME_FOREVER);
				CloseHandle(hPanel);
			}
		}
		// Edit details like position and rotation
		else if(StrEqual(sInfo, "copy"))
		{
			SaveToClipboard(param1, zoneData);
			PrintToChat(param1, "Map Zones > Copied zone \"%s\" to clipboard.", zoneData[ZD_name]);
			DisplayZoneEditMenu(param1);
		}
		// Change the name of the zone
		else if(StrEqual(sInfo, "rename"))
		{
			PrintToChat(param1, "Map Zones > Type new name in chat for zone \"%s\" or \"!abort\" to cancel renaming.", zoneData[ZD_name]);
			g_ClientMenuState[param1][CMS_rename] = true;
		}
		// delete the zone
		else if(StrEqual(sInfo, "delete"))
		{
			decl String:sBuffer[128];
			new Handle:hPanel = CreatePanel();
			Format(sBuffer, sizeof(sBuffer), "Do you really want to delete zone \"%s\"?", zoneData[ZD_name]);
			SetPanelTitle(hPanel, sBuffer);
			
			Format(sBuffer, sizeof(sBuffer), "%T", "Yes", param1);
			DrawPanelItem(hPanel, sBuffer);
			Format(sBuffer, sizeof(sBuffer), "%T", "No", param1);
			DrawPanelItem(hPanel, sBuffer);
			
			SendPanelToClient(hPanel, param1, Panel_HandleConfirmDeleteZone, MENU_TIME_FOREVER);
			CloseHandle(hPanel);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_zone] = -1;
		if(param2 == MenuCancel_ExitBack)
		{
			if(g_ClientMenuState[param1][CMS_cluster] != -1)
				DisplayClusterEditMenu(param1);
			else
				DisplayZoneListMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
		}
	}
}

DisplayZoneEditDetailsMenu(client)
{
	new group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);

	if(zoneData[ZD_deleted])
	{
		DisplayGroupRootMenu(client, group);
		return;
	}
	
	new Handle:hMenu = CreateMenu(Menu_HandleZoneEditDetails);
	SetMenuExitBackButton(hMenu, true);
	if(g_ClientMenuState[client][CMS_cluster] == -1)
		SetMenuTitle(hMenu, "Edit zone \"%s\" in group \"%s\"", zoneData[ZD_name], group[ZG_name]);
	else
	{
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
		SetMenuTitle(hMenu, "Edit zone \"%s\" in cluster \"%s\" of group \"%s\"", zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
	}
	
	AddMenuItem(hMenu, "position1", "Change first corner");
	AddMenuItem(hMenu, "position2", "Change second corner");
	AddMenuItem(hMenu, "center", "Move center of zone");
	AddMenuItem(hMenu, "rotation", "Change rotation");
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleZoneEditDetails(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup], zoneData[ZoneData];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		// Change one of the 2 positions of the zone
		if(!StrContains(sInfo, "position"))
		{
			g_ClientMenuState[param1][CMS_editState] = (StrEqual(sInfo, "position1")?ZES_first:ZES_second);
			g_ClientMenuState[param1][CMS_editPosition] = true;
			
			// Get the current zone bounds as base to edit from.
			for(new i=0;i<3;i++)
			{
				g_ClientMenuState[param1][CMS_first][i] = zoneData[ZD_position][i] + zoneData[ZD_mins][i];
				g_ClientMenuState[param1][CMS_second][i] = zoneData[ZD_position][i] + zoneData[ZD_maxs][i];
				g_ClientMenuState[param1][CMS_rotation][i] = zoneData[ZD_rotation][i];
			}
			
			TriggerTimer(g_hShowZonesTimer, true);
			DisplayZonePointEditMenu(param1);
		}
		// Change rotation of the zone
		else if(StrEqual(sInfo, "rotation"))
		{
			// Copy current rotation from zoneData to clientstate.
			Array_Copy(zoneData[ZD_rotation], g_ClientMenuState[param1][CMS_rotation], 3);
			g_ClientMenuState[param1][CMS_editRotation] = true;
			// Show box now
			TriggerTimer(g_hShowZonesTimer, true);
			DisplayZoneRotationMenu(param1);
		}
		// Keep mins & maxs the same and move the center position.
		else if(StrEqual(sInfo, "center"))
		{
			// Copy current position from zoneData to clientstate.
			Array_Copy(zoneData[ZD_position], g_ClientMenuState[param1][CMS_center], 3);
			g_ClientMenuState[param1][CMS_editCenter] = true;
			// Show box now
			TriggerTimer(g_hShowZonesTimer, true);
			DisplayZonePointEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayZoneEditMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
		}
	}
}

DisplayClusterSelectionMenu(client)
{
	new group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	
	new Handle:hMenu = CreateMenu(Menu_HandleClusterSelection);
	SetMenuTitle(hMenu, "Add zone \"%s\" to cluster:", zoneData[ZD_name]);
	SetMenuExitBackButton(hMenu, true);

	AddMenuItem(hMenu, "newcluster", "Add new cluster\n \n");
	
	new iNumClusters = GetArraySize(group[ZG_cluster]);
	new zoneCluster[ZoneCluster], String:sIndex[16], iClusterCount;
	for(new i=0;i<iNumClusters;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		
		if(zoneCluster[ZC_deleted])
			continue;
		
		IntToString(i, sIndex, sizeof(sIndex));
		AddMenuItem(hMenu, sIndex, zoneCluster[ZC_name]);
		iClusterCount++;
	}
	
	if(!iClusterCount)
		AddMenuItem(hMenu, "", "No clusters available.", ITEMDRAW_DISABLED);
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleClusterSelection(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		if (StrEqual(sInfo, "newcluster"))
		{
			PrintToChat(param1, "Map Zones > Enter name of new cluster in chat. Type \"!abort\" to abort.");
			g_ClientMenuState[param1][CMS_addCluster] = true;
			return;
		}
		
		new group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		new iClusterIndex = StringToInt(sInfo);
		GetZoneClusterByIndex(iClusterIndex, group, zoneCluster);
		// That cluster isn't available anymore..
		if(zoneCluster[ZC_deleted])
		{
			DisplayClusterSelectionMenu(param1);
			return;
		}
		
		PrintToChat(param1, "Map Zones > Zone \"%s\" is now part of cluster \"%s\".", zoneData[ZD_name], zoneCluster[ZC_name]);
		
		zoneData[ZD_clusterIndex] = iClusterIndex;
		SaveZone(group, zoneData);
		DisplayZoneEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayZoneEditMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

public Panel_HandleConfirmRemoveFromCluster(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_Select)
	{
		// Selected "Yes" -> remove zone from cluster.
		if(param2 == 1)
		{
			new group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
			if(zoneData[ZD_clusterIndex] != -1)
				GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
			
			zoneData[ZD_clusterIndex] = -1;
			SaveZone(group, zoneData);
			
			LogAction(param1, -1, "%L removed zone \"%s\" from cluster \"%s\" in group \"%s\".", param1, zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
		}
		
		DisplayZoneEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_group] = -1;
		g_ClientMenuState[param1][CMS_cluster] = -1;
		g_ClientMenuState[param1][CMS_zone] = -1;
	}
}

public Panel_HandleConfirmDeleteZone(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_Select)
	{
		// Selected "Yes" -> delete the zone.
		if(param2 == 1)
		{
			new group[ZoneGroup], zoneData[ZoneData];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
			
			// We can't really delete it, because the array indicies would shift. Just don't save it to file and skip it.
			zoneData[ZD_deleted] = true;
			SaveZone(group, zoneData);
			RemoveZoneTrigger(group, zoneData);
			g_ClientMenuState[param1][CMS_zone] = -1;
			
			
			if(g_ClientMenuState[param1][CMS_cluster] == -1)
			{
				LogAction(param1, -1, "%L deleted zone \"%s\" of group \"%s\".", param1, zoneData[ZD_name], group[ZG_name]);
				DisplayZoneListMenu(param1);
			}
			else
			{
				new zoneCluster[ZoneCluster];
				if(zoneData[ZD_clusterIndex] != -1)
					GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
				LogAction(param1, -1, "%L deleted zone \"%s\" from cluster \"%s\" of group \"%s\".", param1, zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
				DisplayClusterEditMenu(param1);
			}
		}
		else
		{
			DisplayZoneEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_group] = -1;
		g_ClientMenuState[param1][CMS_cluster] = -1;
		g_ClientMenuState[param1][CMS_zone] = -1;
	}
}

// Edit one of the points or the center of the zone.
DisplayZonePointEditMenu(client)
{
	// Start the display timer, if this is the first time we open this menu.
	if (!g_hShowZoneWhileEditTimer[client])
		g_hShowZoneWhileEditTimer[client] = CreateTimer(0.1, Timer_ShowZoneWhileAdding, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);

	new group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	
	new Handle:hMenu = CreateMenu(Menu_HandleZonePointEdit);
	if(g_ClientMenuState[client][CMS_addZone])
	{
		SetMenuTitle(hMenu, "Add new zone > Position %d\nClick on the point or push \"e\" to set it at your feet.", _:g_ClientMenuState[client][CMS_editState]+1);
	}
	else
	{
		new zoneData[ZoneData];
		GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
		if(g_ClientMenuState[client][CMS_editCenter])
		{
			SetMenuTitle(hMenu, "Edit zone \"%s\" center\nClick on the point or push \"e\" to set it at your feet.", zoneData[ZD_name]);
		}
		else
		{
			SetMenuTitle(hMenu, "Edit zone \"%s\" position %d\nClick on the point or push \"e\" to set it at your feet.", zoneData[ZD_name], _:g_ClientMenuState[client][CMS_editState]+1);
		}
	}
	SetMenuExitBackButton(hMenu, true);

	if(!g_ClientMenuState[client][CMS_addZone])
		AddMenuItem(hMenu, "save", "Save changes");
	
	new String:sBuffer[256] = "Show preview: ";
	switch (g_ClientMenuState[client][CMS_previewMode])
	{
		case ZPM_aim:
			StrCat(sBuffer, sizeof(sBuffer), "Aim");
		case ZPM_feet:
			StrCat(sBuffer, sizeof(sBuffer), "At your feet");
	}
	AddMenuItem(hMenu, "togglepreview", sBuffer);
	
	Format(sBuffer, sizeof(sBuffer), "Stepsize: %.0f", g_fStepsizes[g_ClientMenuState[client][CMS_stepSizeIndex]]);
	AddMenuItem(hMenu, "togglestepsize", sBuffer);
	
	if (g_ClientMenuState[client][CMS_aimCapDistance] < 0.0)
	{
		Format(sBuffer, sizeof(sBuffer), "Max. aim distance: Disabled");
		if (g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
			Format(sBuffer, sizeof(sBuffer), "%s\nHold rightclick and move mouse up and down to change.", sBuffer);
		AddMenuItem(hMenu, "resetaimdistance", sBuffer, ITEMDRAW_DISABLED);
	}
	else
	{
		Format(sBuffer, sizeof(sBuffer), "Max. aim distance: %.2f", g_ClientMenuState[client][CMS_aimCapDistance]);
		if (g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
			Format(sBuffer, sizeof(sBuffer), "%s\nHold rightclick and move mouse up and down to change.", sBuffer);
		Format(sBuffer, sizeof(sBuffer), "%s\nSelect menu option to remove limit.", sBuffer);
		AddMenuItem(hMenu, "resetaimdistance", sBuffer);
	}
	
	Format(sBuffer, sizeof(sBuffer), "Snap to map grid: %s", g_ClientMenuState[client][CMS_snapToGrid]?"Enabled":"Disabled");
	AddMenuItem(hMenu, "togglegridsnap", sBuffer);
	
	if(!g_ClientMenuState[client][CMS_addZone])
		AddMenuItem(hMenu, "axismenu", "Move point on axes through menu");
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleZonePointEdit(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		if(StrEqual(sInfo, "save"))
		{
			new zoneData[ZoneData];
			GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
			// Save the new center of the zone.
			// The rotation and mins/maxs stay the same, so not much to do.
			if(g_ClientMenuState[param1][CMS_editCenter])
			{
				Array_Copy(g_ClientMenuState[param1][CMS_center], zoneData[ZD_position], 3);
				g_ClientMenuState[param1][CMS_editCenter] = false;
			}
			else
			{
				// Save the new position of one of the points.
				// Need to recalculate the center and mins/maxs now.
				SaveChangedZoneCoordinates(param1, zoneData);
				Array_Copy(g_ClientMenuState[param1][CMS_rotation], zoneData[ZD_rotation], 3);
				// Find a better fitting trigger model for the new zone
				// next time this zone is created.
				zoneData[ZD_triggerModel][0] = '\0';
				g_ClientMenuState[param1][CMS_editPosition] = false;
				g_ClientMenuState[param1][CMS_editState] = ZES_first;
			}
			
			SaveZone(group, zoneData);
			SetupZone(group, zoneData);
			
			ResetZoneAddingState(param1);
			DisplayZoneEditDetailsMenu(param1);
			TriggerTimer(g_hShowZonesTimer, true);
			return;
		}
		
		// User wants to edit the points through the menu.
		if(StrEqual(sInfo, "axismenu"))
		{
			// Don't show the zone preview anymore, so the user doesn't get distracted.
			g_ClientMenuState[param1][CMS_disablePreview] = true;
			DisplayPointAxisModificationMenu(param1);
			return;
		}
		
		// Toggle through all available zone preview modes
		if(StrEqual(sInfo, "togglepreview"))
		{
			g_ClientMenuState[param1][CMS_previewMode]++;
			if(g_ClientMenuState[param1][CMS_previewMode] >= ZonePreviewMode)
				g_ClientMenuState[param1][CMS_previewMode] = ZPM_aim;
		}
		// Toggle through all the different step sizes.
		else if(StrEqual(sInfo, "togglestepsize"))
		{
			g_ClientMenuState[param1][CMS_stepSizeIndex] = (g_ClientMenuState[param1][CMS_stepSizeIndex] + 1) % sizeof(g_fStepsizes);
		}
		// Remove the aim culling distance when adding points.
		else if(StrEqual(sInfo, "resetaimdistance"))
		{
			g_ClientMenuState[param1][CMS_aimCapDistance] = -1.0;
		}
		else if(StrEqual(sInfo, "togglegridsnap"))
		{
			g_ClientMenuState[param1][CMS_snapToGrid] = !g_ClientMenuState[param1][CMS_snapToGrid];
		}
		
		DisplayZonePointEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		// When the player is currently changing the aim distance cap, we're replacing this with ourselves.
		if(param2 == MenuCancel_Interrupted
		&& g_ClientMenuState[param1][CMS_redrawPointMenu])
		{
			g_ClientMenuState[param1][CMS_redrawPointMenu] = false;
			return;
		}
		
		new bool:bAdding = g_ClientMenuState[param1][CMS_addZone];
		g_ClientMenuState[param1][CMS_editCenter] = false;
		g_ClientMenuState[param1][CMS_editPosition] = false;
		g_ClientMenuState[param1][CMS_editState] = ZES_first;
		g_ClientMenuState[param1][CMS_redrawPointMenu] = false;
		ResetZoneAddingState(param1);
		if(param2 == MenuCancel_ExitBack)
		{
			if(bAdding)
				DisplayZoneListMenu(param1);
			else
				DisplayZoneEditDetailsMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

DisplayPointAxisModificationMenu(client)
{
	new group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	
	new Handle:hMenu = CreateMenu(Menu_HandlePointAxisEdit);
	SetMenuExitBackButton(hMenu, true);
	
	new String:sBuffer[256];
	if(g_ClientMenuState[client][CMS_editCenter])
	{
		Format(sBuffer, sizeof(sBuffer), "Edit center of zone \"%s\"", zoneData[ZD_name]);
	}
	else
	{
		Format(sBuffer, sizeof(sBuffer), "Edit zone \"%s\" position %d", zoneData[ZD_name], _:g_ClientMenuState[client][CMS_editState]+1);
	}
	Format(sBuffer, sizeof(sBuffer), "%s\nMove position along the axes.\nStepsize: %.f\n\nGo back to save changes!", sBuffer, g_fStepsizes[g_ClientMenuState[client][CMS_stepSizeIndex]]);
	SetMenuTitle(hMenu, sBuffer);

	AddMenuItem(hMenu, "ax", "Add to X axis (red)");
	AddMenuItem(hMenu, "sx", "Subtract from X axis");
	AddMenuItem(hMenu, "ay", "Add to Y axis (green)");
	AddMenuItem(hMenu, "sy", "Subtract from Y axis");
	AddMenuItem(hMenu, "az", "Add to Z axis (blue)");
	AddMenuItem(hMenu, "sz", "Subtract from Z axis");
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandlePointAxisEdit(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup], zoneData[ZoneData];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		// Add to x
		new Float:fValue = g_fStepsizes[g_ClientMenuState[param1][CMS_stepSizeIndex]];
		if(sInfo[0] == 's')
			fValue *= -1.0;
		
		new iAxis = sInfo[1] - 'x';
		
		// Apply value to selected point of the zone.
		if(g_ClientMenuState[param1][CMS_editCenter])
			g_ClientMenuState[param1][CMS_center][iAxis] += fValue;
		else if(g_ClientMenuState[param1][CMS_editState] == ZES_first)
			g_ClientMenuState[param1][CMS_first][iAxis] += fValue;
		else
			g_ClientMenuState[param1][CMS_second][iAxis] += fValue;
		
		TriggerTimer(g_hShowZonesTimer, true);
		DisplayPointAxisModificationMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_disablePreview] = false;
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayZonePointEditMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_editCenter] = false;
			g_ClientMenuState[param1][CMS_editPosition] = false;
			g_ClientMenuState[param1][CMS_editState] = ZES_first;
			ResetZoneAddingState(param1);
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

DisplayZoneRotationMenu(client)
{
	new group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	
	new Handle:hMenu = CreateMenu(Menu_HandleZoneRotation);
	SetMenuTitle(hMenu, "Rotate zone %s", zoneData[ZD_name]);
	SetMenuExitBackButton(hMenu, true);
	
	AddMenuItem(hMenu, "", "Hold \"e\" and move your mouse to rotate the box.", ITEMDRAW_DISABLED);
	AddMenuItem(hMenu, "", "Hold \"shift\" too, to rotate around a different axis when moving mouse up and down.", ITEMDRAW_DISABLED);
	
	AddMenuItem(hMenu, "save", "Save rotation");
	AddMenuItem(hMenu, "reset", "Reset rotation");
	AddMenuItem(hMenu, "discard", "Discard new rotation");
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleZoneRotation(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup], zoneData[ZoneData];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		if(StrEqual(sInfo, "save"))
		{
			Array_Copy(g_ClientMenuState[param1][CMS_rotation], zoneData[ZD_rotation], 3);
			SaveZone(group, zoneData);
			SetupZone(group, zoneData);
			g_ClientMenuState[param1][CMS_editRotation] = false;
			Array_Fill(g_ClientMenuState[param1][CMS_rotation], 3, 0.0);
			DisplayZoneEditDetailsMenu(param1);
		}
		else if(StrEqual(sInfo, "reset"))
		{
			Array_Fill(g_ClientMenuState[param1][CMS_rotation], 3, 0.0);
			TriggerTimer(g_hShowZonesTimer, true);
			DisplayZoneRotationMenu(param1);
		}
		else if(StrEqual(sInfo, "discard"))
		{
			Array_Fill(g_ClientMenuState[param1][CMS_rotation], 3, 0.0);
			g_ClientMenuState[param1][CMS_editRotation] = false;
			DisplayZoneEditDetailsMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_editRotation] = false;
		Array_Fill(g_ClientMenuState[param1][CMS_rotation], 3, 0.0);
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayZoneEditDetailsMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

DisplayZoneAddFinalizationMenu(client)
{
	if(g_ClientMenuState[client][CMS_group] == -1)
		return;
	
	new group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	
	new Handle:hMenu = CreateMenu(Menu_HandleAddFinalization);
	if(g_ClientMenuState[client][CMS_cluster] == -1)
		SetMenuTitle(hMenu, "Save new zone in group \"%s\"?", group[ZG_name]);
	else
	{
		new zoneCluster[ZoneCluster];
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
		SetMenuTitle(hMenu, "Save new zone in cluster \"%s\" of group \"%s\"?", zoneCluster[ZC_name], group[ZG_name]);
	}
	SetMenuExitBackButton(hMenu, true);
	
	new String:sBuffer[128];
	// When pasting a zone we want to edit the center position afterwards right away.
	if(g_ClientMenuState[client][CMS_editCenter])
	{
		Format(sBuffer, sizeof(sBuffer), "Pasting new copy of zone \"%s\".\nYou can place the copy after giving it a name.", g_Clipboard[client][CB_name]);
		AddMenuItem(hMenu, "", sBuffer, ITEMDRAW_DISABLED);
	}
	
	AddMenuItem(hMenu, "", "Type zone name in chat to save it. (\"!abort\" to abort)", ITEMDRAW_DISABLED);
	
	GetFreeAutoZoneName(group, sBuffer, sizeof(sBuffer));
	Format(sBuffer, sizeof(sBuffer), "Use auto-generated zone name (%s)", sBuffer);
	AddMenuItem(hMenu, "autoname", sBuffer);
	AddMenuItem(hMenu, "discard", "Discard new zone");
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandleAddFinalization(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if(action == MenuAction_Select)
	{
		new String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		// Add the zone using a generated name
		if(StrEqual(sInfo, "autoname"))
		{
			new String:sBuffer[128];
			GetFreeAutoZoneName(group, sBuffer, sizeof(sBuffer));
			SaveNewZone(param1, sBuffer);
		}
		// delete the zone
		else if(StrEqual(sInfo, "discard"))
		{
			ResetZoneAddingState(param1);
			// In case we were pasting a zone from clipboard.
			g_ClientMenuState[param1][CMS_editCenter] = false;
			if(g_ClientMenuState[param1][CMS_cluster] == -1)
				DisplayZoneListMenu(param1);
			else
				DisplayClusterEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		ResetZoneAddingState(param1);
		if(param2 == MenuCancel_ExitBack)
		{
			// In case we were pasting a zone from clipboard.
			g_ClientMenuState[param1][CMS_editCenter] = false;
			if(g_ClientMenuState[param1][CMS_cluster] != -1)
			{
				DisplayClusterEditMenu(param1);
			}
			else
			{
				DisplayZoneListMenu(param1);
			}
		}
		// Only reset state, if we didn't type a name in chat!
		else if(g_ClientMenuState[param1][CMS_zone] == -1)
		{
			// In case we were pasting a zone from clipboard.
			g_ClientMenuState[param1][CMS_editCenter] = false;
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
		}
	}
}

/**
 * Zone information persistence in configs
 */
bool:LoadZoneGroup(group[ZoneGroup])
{
	decl String:sPath[PLATFORM_MAX_PATH], String:sMap[128];
	GetCurrentMap(sMap, sizeof(sMap));
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/mapzonelib/%s/%s.zones", group[ZG_name], sMap);
	
	if(!FileExists(sPath))
		return false;
	
	new Handle:hKV = CreateKeyValues("MapZoneGroup");
	if(!hKV)
		return false;
	
	// Allow \" and \n escapeing
	KvSetEscapeSequences(hKV, true);
	
	if(!FileToKeyValues(hKV, sPath))
		return false;
	
	if(!KvGotoFirstSubKey(hKV))
		return false;
	
	new Float:vBuf[3], String:sZoneName[MAX_ZONE_NAME];
	new String:sBuffer[32];
	new zoneCluster[ZoneCluster];
	zoneCluster[ZC_index] = -1;
	
	do {
		KvGetSectionName(hKV, sBuffer, sizeof(sBuffer));
		// This is the start of a cluster group.
		if(!StrContains(sBuffer, "cluster", false))
		{
			// A cluster in a cluster? nope..
			if(zoneCluster[ZC_index] != -1)
				continue;
			
			// Get the cluster name
			KvGetString(hKV, "name", sZoneName, sizeof(sZoneName), "unnamed");
			strcopy(zoneCluster[ZC_name][0], MAX_ZONE_NAME, sZoneName);
			zoneCluster[ZC_teamFilter] = KvGetNum(hKV, "team");
			
			new iColor[4];
			KvGetColor(hKV, "color", iColor[0], iColor[1], iColor[2], iColor[3]);
			if (iColor[0] == 0 && iColor[1] == 0 && iColor[2] == 0 && iColor[3] == 0)
				Array_Fill(iColor, sizeof(iColor), -1);
			Array_Copy(iColor, zoneCluster[ZC_color], sizeof(iColor));
			
			// See if there is a custom keyvalues section for this cluster.
			if(KvJumpToKey(hKV, "custom", false) && KvGotoFirstSubKey(hKV, false))
			{
				zoneCluster[ZC_customKV] = CreateTrie();
				ParseCustomKeyValues(hKV, zoneCluster[ZC_customKV]);
				KvGoBack(hKV); // KvGotoFirstSubKey
				KvGoBack(hKV); // KvJumpToKey
			}
			
			zoneCluster[ZC_index] = GetArraySize(group[ZG_cluster]);
			PushArrayArray(group[ZG_cluster], zoneCluster[0], _:ZoneCluster);
			
			// Step inside this group
			KvGotoFirstSubKey(hKV);
		}
		
		// Don't parse the custom section as a zone of a cluster.
		KvGetSectionName(hKV, sBuffer, sizeof(sBuffer));
		if (StrEqual(sBuffer, "custom", false))
			continue;
		
		new zoneData[ZoneData];
		KvGetVector(hKV, "pos", vBuf);
		Array_Copy(vBuf, zoneData[ZD_position], 3);
		
		KvGetVector(hKV, "mins", vBuf);
		Array_Copy(vBuf, zoneData[ZD_mins], 3);
		
		KvGetVector(hKV, "maxs", vBuf);
		Array_Copy(vBuf, zoneData[ZD_maxs], 3);
		
		KvGetVector(hKV, "rotation", vBuf);
		Array_Copy(vBuf, zoneData[ZD_rotation], 3);
		
		zoneData[ZD_teamFilter] = KvGetNum(hKV, "team");
		
		new iColor[4];
		KvGetColor(hKV, "color", iColor[0], iColor[1], iColor[2], iColor[3]);
		if (iColor[0] == 0 && iColor[1] == 0 && iColor[2] == 0 && iColor[3] == 0)
				Array_Fill(iColor, sizeof(iColor), -1);
		Array_Copy(iColor, zoneData[ZD_color], sizeof(iColor));
		
		KvGetString(hKV, "name", sZoneName, sizeof(sZoneName), "unnamed");
		strcopy(zoneData[ZD_name][0], MAX_ZONE_NAME, sZoneName);
		
		// See if there is a custom keyvalues section for this zone.
		// Step inside.
		if(KvJumpToKey(hKV, "custom", false) && KvGotoFirstSubKey(hKV, false))
		{
			//if(zoneCluster[ZC_index] != -1)
			//{
			//	LogError("No custom keyvalues allowed in individual cluster zones (%s, %s, %s)", group[ZG_name], zoneCluster[ZC_name], zoneData[ZD_name]);
			//}
			zoneData[ZD_customKV] = CreateTrie();
			ParseCustomKeyValues(hKV, zoneData[ZD_customKV]);
			KvGoBack(hKV); // KvGotoFirstSubKey
			KvGoBack(hKV); // KvJumpToKey
		}
		
		zoneData[ZD_clusterIndex] = zoneCluster[ZC_index];
		
		zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
		zoneData[ZD_index] = GetArraySize(group[ZG_zones]);
		PushArrayArray(group[ZG_zones], zoneData[0], _:ZoneData);
		
		// Step out of the cluster group if we reached the end.
		KvSavePosition(hKV);
		if(!KvGotoNextKey(hKV) && zoneCluster[ZC_index] != -1)
		{
			zoneCluster[ZC_index] = -1;
			KvGoBack(hKV);
		}
		KvGoBack(hKV);
		
	} while(KvGotoNextKey(hKV));
	
	CloseHandle(hKV);
	return true;
}

ParseCustomKeyValues(Handle:hKV, Handle:hCustomKV)
{
	new String:sKey[128], String:sValue[256];
	do
	{
		KvGetSectionName(hKV, sKey, sizeof(sKey));
		KvGetString(hKV, NULL_STRING, sValue, sizeof(sValue));
		SetTrieString(hCustomKV, sKey, sValue, true);
	} while (KvGotoNextKey(hKV, false));
}

bool:SaveZoneGroupToFile(group[ZoneGroup])
{
	decl String:sPath[PLATFORM_MAX_PATH], String:sMap[128];
	GetCurrentMap(sMap, sizeof(sMap));
	
	new iMode = FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC|FPERM_G_READ|FPERM_G_WRITE|FPERM_G_EXEC|FPERM_O_READ|FPERM_O_EXEC;
	// Have mercy and even create the root config file directory.
	BuildPath(Path_SM, sPath, sizeof(sPath),  "configs/mapzonelib");
	if(!DirExists(sPath))
	{
		if(!CreateDirectory(sPath, iMode)) // mode 0775
			return false;
	}
	
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/mapzonelib/%s", group[ZG_name]);
	if(!DirExists(sPath))
	{
		if(!CreateDirectory(sPath, iMode))
			return false;
	}
	
	new Handle:hKV = CreateKeyValues("MapZoneGroup");
	if(!hKV)
		return false;
	
	// Allow \" and \n escapeing
	KvSetEscapeSequences(hKV, true);
	
	// Add all zones of this group to the keyvalues file.
	// Add normal zones without a cluster first.
	new bool:bZonesAdded = CreateZoneSectionsInKV(hKV, group, -1);
	
	new iNumClusters = GetArraySize(group[ZG_cluster]);
	new zoneCluster[ZoneCluster], iIndex, String:sIndex[32];
	for(new i=0;i<iNumClusters;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		if(zoneCluster[ZC_deleted])
			continue;
		
		Format(sIndex, sizeof(sIndex), "cluster%d", iIndex++);
		KvJumpToKey(hKV, sIndex, true);
		KvSetString(hKV, "name", zoneCluster[ZC_name]);
		KvSetNum(hKV, "team", zoneCluster[ZC_teamFilter]);
		// Only set the color to the KV if it was set.
		if (zoneCluster[ZC_color][0] >= 0)
			KvSetColor(hKV, "color", zoneCluster[ZC_color][0], zoneCluster[ZC_color][1], zoneCluster[ZC_color][2], zoneCluster[ZC_color][3]);
		
		AddCustomKeyValues(hKV, zoneCluster[ZC_customKV]);
		
		// Run through all zones and add the ones that belong to this cluster.
		bZonesAdded |= CreateZoneSectionsInKV(hKV, group, zoneCluster[ZC_index]);
		
		KvGoBack(hKV);
	}
	
	KvRewind(hKV);
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/mapzonelib/%s/%s.zones", group[ZG_name], sMap);
	// Only add zones, if there are any for this map.
	if(bZonesAdded)
	{
		if(!KeyValuesToFile(hKV, sPath))
			LogError("Error saving zones to file %s.", sPath);
	}
	else
	{
		// Remove the zone config otherwise, so we don't keep empty files around.
		DeleteFile(sPath);
	}
	CloseHandle(hKV);
	
	return true;
}

bool:CreateZoneSectionsInKV(Handle:hKV, group[ZoneGroup], iClusterIndex)
{
	new String:sIndex[16], zoneData[ZoneData], Float:vBuf[3];
	new iSize = GetArraySize(group[ZG_zones]);
	new bool:bZonesAdded, iIndex;
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		// Does this belong to the right cluster?
		if(zoneData[ZD_clusterIndex] != iClusterIndex)
			continue;
		
		bZonesAdded = true;
		
		IntToString(iIndex++, sIndex, sizeof(sIndex));
		KvJumpToKey(hKV, sIndex, true);
		
		Array_Copy(zoneData[ZD_position], vBuf, 3);
		KvSetVector(hKV, "pos", vBuf);
		Array_Copy(zoneData[ZD_mins], vBuf, 3);
		KvSetVector(hKV, "mins", vBuf);
		Array_Copy(zoneData[ZD_maxs], vBuf, 3);
		KvSetVector(hKV, "maxs", vBuf);
		Array_Copy(zoneData[ZD_rotation], vBuf, 3);
		KvSetVector(hKV, "rotation", vBuf);
		KvSetNum(hKV, "team", zoneData[ZD_teamFilter]);
		// Only set the color to the KV if it was set.
		if (zoneData[ZD_color][0] >= 0)
			KvSetColor(hKV, "color", zoneData[ZD_color][0], zoneData[ZD_color][1], zoneData[ZD_color][2], zoneData[ZD_color][3]);
		KvSetString(hKV, "name", zoneData[ZD_name]);
		
		AddCustomKeyValues(hKV, zoneData[ZD_customKV]);
		
		KvGoBack(hKV);
	}
	
	return bZonesAdded;
}

AddCustomKeyValues(Handle:hKV, Handle:hCustomKV)
{
	if (hCustomKV == INVALID_HANDLE || GetTrieSize(hCustomKV) == 0)
		return;
	
	KvJumpToKey(hKV, "custom", true);
	
	new Handle:hTrieSnapshot = CreateTrieSnapshot(hCustomKV);
	
	new iSize = TrieSnapshotLength(hTrieSnapshot);
	new String:sKey[128], String:sValue[256];
	for (new i=0; i<iSize; i++)
	{
		GetTrieSnapshotKey(hTrieSnapshot, i, sKey, sizeof(sKey));
		GetTrieString(hCustomKV, sKey, sValue, sizeof(sValue));
		KvSetString(hKV, sKey, sValue);
	}
	
	CloseHandle(hTrieSnapshot);
	KvGoBack(hKV);
}

SaveAllZoneGroupsToFile()
{
	new group[ZoneGroup];
	new iSize = GetArraySize(g_hZoneGroups);
	for(new i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		if(!SaveZoneGroupToFile(group))
			LogError("Error creating \"configs/mapzonelib/%s/\" folder. Didn't save any zones in that group.", group[ZG_name]);
	}
}

LoadAllGroupZones()
{
	new group[ZoneGroup];
	new iSize = GetArraySize(g_hZoneGroups);
	for(new i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		LoadZoneGroup(group);
	}
}

/**
 * Zone trigger handling
 */
SetupGroupZones(group[ZoneGroup])
{
	new iSize = GetArraySize(group[ZG_zones]);
	new zoneData[ZoneData];
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		SetupZone(group, zoneData);
	}
}

bool:SetupZone(group[ZoneGroup], zoneData[ZoneData])
{
	// Refuse to create a trigger for a soft-deleted zone.
	if(zoneData[ZD_deleted])
		return false;

	new iTrigger = CreateEntityByName("trigger_multiple");
	if(iTrigger == INVALID_ENT_REFERENCE)
		return false;
	
	decl String:sTargetName[64];
	Format(sTargetName, sizeof(sTargetName), "mapzonelib_%d_%d", group[ZG_index], zoneData[ZD_index]);
	DispatchKeyValue(iTrigger, "targetname", sTargetName);
	
	DispatchKeyValue(iTrigger, "spawnflags", "1"); // triggers on clients (players) only
	DispatchKeyValue(iTrigger, "wait", "0");
	
	// Make sure any old trigger is gone.
	RemoveZoneTrigger(group, zoneData);
	
	new Float:fRotation[3];
	Array_Copy(zoneData[ZD_rotation], fRotation, 3);
	new bool:bIsRotated = !Math_VectorsEqual(fRotation, Float:{0.0,0.0,0.0});
	
	// Get "model" of one of the present brushes in the map.
	// Only those models (and the map .bsp itself) are accepted as brush models.
	// Only brush models get the BSP solid type and so traces check rotation too.
	if(bIsRotated)
	{
		FindSmallestExistingEncapsulatingTrigger(zoneData);
		DispatchKeyValue(iTrigger, "model", zoneData[ZD_triggerModel]);
	}
	else
	{
		DispatchKeyValue(iTrigger, "model", "models/error.mdl");
	}
	
	zoneData[ZD_triggerEntity] = EntIndexToEntRef(iTrigger);
	SaveZone(group, zoneData);
	
	DispatchSpawn(iTrigger);
	// See if that zone is restricted to one team.
	if(!ApplyTeamRestrictionFilter(group, zoneData))
		// Only activate, if we didn't set a filter. Don't need to do it twice.
		ActivateEntity(iTrigger);
	
	// If trigger is rotated consider rotation in traces
	if(bIsRotated)
		Entity_SetSolidType(iTrigger, SOLID_BSP);
	else
		Entity_SetSolidType(iTrigger, SOLID_BBOX);
		
	ApplyNewTriggerBounds(zoneData);
	
	// Add the EF_NODRAW flag to keep the engine from trying to render the trigger.
	new iEffects = GetEntProp(iTrigger, Prop_Send, "m_fEffects");
	iEffects |= 32;
	SetEntProp(iTrigger, Prop_Send, "m_fEffects", iEffects);

	HookSingleEntityOutput(iTrigger, "OnStartTouch", EntOut_OnTouchEvent);
	HookSingleEntityOutput(iTrigger, "OnTrigger", EntOut_OnTouchEvent);
	HookSingleEntityOutput(iTrigger, "OnEndTouch", EntOut_OnTouchEvent);
	
	return true;
}

ApplyNewTriggerBounds(zoneData[ZoneData])
{
	new iTrigger = EntRefToEntIndex(zoneData[ZD_triggerEntity]);
	if(iTrigger == INVALID_ENT_REFERENCE)
		return;
	
	new Float:fPos[3], Float:fAngles[3];
	Array_Copy(zoneData[ZD_position], fPos, 3);
	Array_Copy(zoneData[ZD_rotation], fAngles, 3);
	TeleportEntity(iTrigger, fPos, fAngles, NULL_VECTOR);

	new Float:fMins[3], Float:fMaxs[3];
	Array_Copy(zoneData[ZD_mins], fMins, 3);
	Array_Copy(zoneData[ZD_maxs], fMaxs, 3);
	Entity_SetMinMaxSize(iTrigger, fMins, fMaxs);
	
	AcceptEntityInput(iTrigger, "Disable");
	AcceptEntityInput(iTrigger, "Enable");
}

bool:ApplyTeamRestrictionFilter(group[ZoneGroup], zoneData[ZoneData])
{
	new iTrigger = EntRefToEntIndex(zoneData[ZD_triggerEntity]);
	if(iTrigger == INVALID_ENT_REFERENCE)
		return false;
	
	// See if that zone is restricted to one team.
	if(zoneData[ZD_teamFilter] >= 2 && zoneData[ZD_teamFilter] <= 3)
	{
		new String:sTargetName[64];
		Format(sTargetName, sizeof(sTargetName), "mapzone_filter_team%d", zoneData[ZD_teamFilter]);
		if(group[ZG_filterEntTeam][zoneData[ZD_teamFilter]-2] == INVALID_ENT_REFERENCE || EntRefToEntIndex(group[ZG_filterEntTeam][zoneData[ZD_teamFilter]-2]) == INVALID_ENT_REFERENCE)
		{
			new iFilter = CreateEntityByName("filter_activator_team");
			if(iFilter == INVALID_ENT_REFERENCE)
			{
				LogError("Can't create filter_activator_team trigger filter entity. Won't create zone %s", zoneData[ZD_name]);
				AcceptEntityInput(iTrigger, "Kill");
				zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
				SaveZone(group, zoneData);
				return false;
			}
			
			// Name the filter, so we can set the triggers to use it
			DispatchKeyValue(iFilter, "targetname", sTargetName);
			
			// Set the "filterteam" value
			SetEntProp(iFilter, Prop_Data, "m_iFilterTeam", zoneData[ZD_teamFilter]);
			DispatchSpawn(iFilter);
			ActivateEntity(iFilter);
			
			// Save the newly created entity
			group[ZG_filterEntTeam][zoneData[ZD_teamFilter]-2] = iFilter;
			SaveGroup(group);
		}
		
		// Set the filter
		DispatchKeyValue(iTrigger, "filtername", sTargetName);
		ActivateEntity(iTrigger);
		return true;
	}
	return false;
}

FindSmallestExistingEncapsulatingTrigger(zoneData[ZoneData])
{
	// Already found a model. Just use it.
	if(zoneData[ZD_triggerModel][0] != 0)
		return;

	new Float:vMins[3], Float:vMaxs[3];
	new Float:fLength, Float:vDiag[3];
	GetEntPropVector(0, Prop_Data, "m_WorldMins", vMins);
	GetEntPropVector(0, Prop_Data, "m_WorldMaxs", vMaxs);
	
	SubtractVectors(vMins, vMaxs, vDiag);
	fLength = GetVectorLength(vDiag);
	
	//LogMessage("World mins [%f,%f,%f] maxs [%f,%f,%f] diag length %f", XYZ(vMins), XYZ(vMaxs), fLength);
	
	// The map itself would be always large enough - but often it's way too large!
	new Float:fSmallestLength = fLength;
	GetCurrentMap(zoneData[ZD_triggerModel], sizeof(zoneData[ZD_triggerModel]));
	Format(zoneData[ZD_triggerModel], sizeof(zoneData[ZD_triggerModel]), "maps/%s.bsp", zoneData[ZD_triggerModel]);

	new iMaxEnts = GetEntityCount();
	new String:sModel[256], String:sClassname[256], String:sName[64];
	new bool:bLargeEnough;
	for(new i=MaxClients+1;i<iMaxEnts;i++)
	{
		if(!IsValidEntity(i))
			continue;
		
		// Only care for brushes
		Entity_GetModel(i, sModel, sizeof(sModel));
		if(sModel[0] != '*')
			continue;
		
		// Seems like only trigger brush models work as expected with .. triggers.
		Entity_GetClassName(i, sClassname, sizeof(sClassname));
		if(StrContains(sClassname, "trigger_") != 0)
			continue;
		
		// Don't count zones created by ourselves :P
		Entity_GetName(i, sName, sizeof(sName));
		if(!StrContains(sName, "mapzonelib_"))
			continue;
		
		Entity_GetMinSize(i, vMins);
		Entity_GetMaxSize(i, vMaxs);
		
		SubtractVectors(vMins, vMaxs, vDiag);
		fLength = GetVectorLength(vDiag);
		
		bLargeEnough = true;
		for(new v=0;v<3;v++)
		{
			if(vMins[v] > zoneData[ZD_mins][v]
			|| vMaxs[v] < zoneData[ZD_maxs][v])
			{
				bLargeEnough = false;
				break;
			}
		}
		if(bLargeEnough && fLength < fSmallestLength)
		{
			fSmallestLength = fLength;
			strcopy(zoneData[ZD_triggerModel], sizeof(zoneData[ZD_triggerModel]), sModel);
		}
		
		//LogMessage("%s (%s) #%d: model \"%s\" mins [%f,%f,%f] maxs [%f,%f,%f] diag length %f", sClassname, sName, i, sModel, XYZ(vMins), XYZ(vMaxs), fLength);
	}
	
	//LogMessage("Smallest entity which encapsulates zone %s is %s with diagonal length %f.", zoneData[ZD_name], zoneData[ZD_triggerModel], fSmallestLength);
}

SetupAllGroupZones()
{
	new group[ZoneGroup];
	new iSize = GetArraySize(g_hZoneGroups);
	for(new i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		SetupGroupZones(group);
	}
}

RemoveZoneTrigger(group[ZoneGroup], zoneData[ZoneData])
{
	new iTrigger = EntRefToEntIndex(zoneData[ZD_triggerEntity]);
	if(iTrigger == INVALID_ENT_REFERENCE)
		return;
	
	// Fire leave callback for all touching clients.
	for(new i=1;i<=MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		if(!zoneData[ZD_clientInZone][i])
			continue;
		
		// Make all players leave this zone. It's gone now.
		AcceptEntityInput(iTrigger, "EndTouch", i, i);
	}
	
	zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
	SaveZone(group, zoneData);
	
	AcceptEntityInput(iTrigger, "Kill");
}

/**
 * Zone helpers / accessors
 */
ClearZonesInGroups()
{
	new group[ZoneGroup];
	new iSize = GetArraySize(g_hZoneGroups);
	for(new i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		
		CloseCustomKVInZones(group);
		ClearArray(group[ZG_zones]);
		
		CloseCustomKVInClusters(group);
		ClearArray(group[ZG_cluster]);
	}
}

CloseCustomKVInZones(group[ZoneGroup])
{
	new zoneData[ZoneData];
	new iSize = GetArraySize(group[ZG_zones]);
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		
		if (!zoneData[ZD_customKV])
			continue;
		
		CloseHandle(zoneData[ZD_customKV]);
	}
}

CloseCustomKVInClusters(group[ZoneGroup])
{
	new zoneCluster[ZoneCluster];
	new iSize = GetArraySize(group[ZG_cluster]);
	for(new i=0;i<iSize;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		
		if (!zoneCluster[ZC_customKV])
			continue;
		
		CloseHandle(zoneCluster[ZC_customKV]);
	}
}

GetGroupByIndex(iIndex, group[ZoneGroup])
{
	GetArrayArray(g_hZoneGroups, iIndex, group[0], _:ZoneGroup);
}

bool:GetGroupByName(const String:sName[], group[ZoneGroup])
{
	new iSize = GetArraySize(g_hZoneGroups);
	for(new i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		if(StrEqual(group[ZG_name], sName, false))
			return true;
	}
	return false;
}

SaveGroup(group[ZoneGroup])
{
	SetArrayArray(g_hZoneGroups, group[ZG_index], group[0], _:ZoneGroup);
}

GetZoneByIndex(iIndex, group[ZoneGroup], zoneData[ZoneData])
{
	GetArrayArray(group[ZG_zones], iIndex, zoneData[0], _:ZoneData);
}

bool:GetZoneByName(const String:sName[], group[ZoneGroup], zoneData[ZoneData])
{
	new iSize = GetArraySize(group[ZG_zones]);
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		if(StrEqual(zoneData[ZD_name], sName, false))
			return true;
	}
	return false;
}

SaveZone(group[ZoneGroup], zoneData[ZoneData])
{
	SetArrayArray(group[ZG_zones], zoneData[ZD_index], zoneData[0], _:ZoneData);
}

bool:ZoneExistsWithName(group[ZoneGroup], const String:sZoneName[])
{
	new zoneData[ZoneData];
	return GetZoneByName(sZoneName, group, zoneData);
}

GetZoneClusterByIndex(iIndex, group[ZoneGroup], zoneCluster[ZoneCluster])
{
	GetArrayArray(group[ZG_cluster], iIndex, zoneCluster[0], _:ZoneCluster);
}

bool:GetZoneClusterByName(const String:sName[], group[ZoneGroup], zoneCluster[ZoneCluster])
{
	new iSize = GetArraySize(group[ZG_cluster]);
	for(new i=0;i<iSize;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		if(zoneCluster[ZC_deleted])
			continue;
		
		if(StrEqual(zoneCluster[ZC_name], sName, false))
			return true;
	}
	return false;
}

SaveCluster(group[ZoneGroup], zoneCluster[ZoneCluster])
{
	SetArrayArray(group[ZG_cluster], zoneCluster[ZC_index], zoneCluster[0], _:ZoneCluster);
}

bool:ClusterExistsWithName(group[ZoneGroup], const String:sClusterName[])
{
	new zoneCluster[ZoneCluster];
	return GetZoneClusterByName(sClusterName, group, zoneCluster);
}

RemoveClientFromAllZones(client)
{
	new iNumGroups = GetArraySize(g_hZoneGroups);
	new iNumZones, group[ZoneGroup], zoneData[ZoneData];
	for(new i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		iNumZones = GetArraySize(group[ZG_zones]);
		for(new z=0;z<iNumZones;z++)
		{
			GetZoneByIndex(z, group, zoneData);
			if(zoneData[ZD_deleted])
				continue;
			
			// Not in this zone?
			if(!zoneData[ZD_clientInZone][client])
				continue;
			
			// No trigger on the map?
			if(zoneData[ZD_triggerEntity] == INVALID_ENT_REFERENCE)
				continue;
			
			if(!IsClientInGame(client))
			{
				zoneData[ZD_clientInZone][client] = false;
				SaveZone(group, zoneData);
				continue;
			}
			
			AcceptEntityInput(EntRefToEntIndex(zoneData[ZD_triggerEntity]), "EndTouch", client, client);
		}
	}
}

/**
 * Zone adding
 */
bool:IsClientEditingZonePosition(client)
{
	return g_ClientMenuState[client][CMS_addZone] || g_ClientMenuState[client][CMS_editPosition] || g_ClientMenuState[client][CMS_editCenter];
}

HandleZonePositionSetting(client, const Float:fOrigin[3])
{
	if(g_ClientMenuState[client][CMS_addZone] || g_ClientMenuState[client][CMS_editPosition])
	{
		if(g_ClientMenuState[client][CMS_editState] == ZES_first)
		{
			Array_Copy(fOrigin, g_ClientMenuState[client][CMS_first], 3);
			if(g_ClientMenuState[client][CMS_addZone])
			{
				g_ClientMenuState[client][CMS_editState] = ZES_second;
				g_ClientMenuState[client][CMS_redrawPointMenu] = true;
				DisplayZonePointEditMenu(client);
				PrintToChat(client, "Map Zones > Now click on the opposing diagonal edge of the zone or push \"e\" to set it at your feet.");
			}
			else
			{
				// Setting one point is tricky when using rotations.
				// We have to reset the rotation here.
				Array_Fill(g_ClientMenuState[client][CMS_rotation], 3, 0.0);
				HandleZoneDefaultHeight(g_ClientMenuState[client][CMS_first][2], g_ClientMenuState[client][CMS_second][2]);
			
				// Show the new zone immediately
				TriggerTimer(g_hShowZonesTimer, true);
			}
		}
		else if(g_ClientMenuState[client][CMS_editState] == ZES_second)
		{
			Array_Copy(fOrigin, g_ClientMenuState[client][CMS_second], 3);
			HandleZoneDefaultHeight(g_ClientMenuState[client][CMS_first][2], g_ClientMenuState[client][CMS_second][2]);
			
			// Setting one point is tricky when using rotations.
			// We have to reset the rotation here.
			Array_Fill(g_ClientMenuState[client][CMS_rotation], 3, 0.0);
			
			if(g_ClientMenuState[client][CMS_addZone])
			{
				g_ClientMenuState[client][CMS_editState] = ZES_name;
				g_ClientMenuState[client][CMS_redrawPointMenu] = true;
				DisplayZoneAddFinalizationMenu(client);
				PrintToChat(client, "Map Zones > Please type a name for this zone in chat. Type \"!abort\" to abort.");
			}
			
			// Show the new zone immediately
			TriggerTimer(g_hShowZonesTimer, true);
		}
	}
	else if(g_ClientMenuState[client][CMS_editCenter])
	{
		Array_Copy(fOrigin, g_ClientMenuState[client][CMS_center], 3);
		// Show the new zone immediately
		TriggerTimer(g_hShowZonesTimer, true);
	}
}

bool:GetClientZoneAimPosition(client, Float:fTarget[3], Float:fUnsnappedTarget[3])
{
	new Float:fClientPosition[3], Float:fClientAngles[3];
	GetClientEyePosition(client, fClientPosition);
	
	// When a player is currently holding rightclick while editing a zone point position,
	// he's trying to adjust the maximal distance of the laserpointer point which specifies the target position.
	// Don't change the pointer position while moving the mouse up and down to change the distance.
	new bool:bIsAdjustingAimLimit = g_ClientMenuState[client][CMS_previewMode] == ZPM_aim && (g_iClientButtons[client] & IN_ATTACK2 == IN_ATTACK2) && IsClientEditingZonePosition(client);
	if (bIsAdjustingAimLimit)
	{
		fClientAngles = g_fAimCapTempAngles[client];
	}
	else
	{
		GetClientEyeAngles(client, fClientAngles);
	}
	
	// See what the client is aiming at.
	new bool:bDidHit;
	TR_TraceRayFilter(fClientPosition, fClientAngles, MASK_SOLID, RayType_Infinite, RayFilter_DontHitSelf, client);
	bDidHit = TR_DidHit();
	
	// See if we need to cap it.
	new Float:fAimDirection[3], Float:fTargetNormal[3];
	// We did hit something over there.
	if (bDidHit)
	{
		TR_GetEndPosition(fUnsnappedTarget);
		
		TR_GetPlaneNormal(INVALID_HANDLE, fTargetNormal);
		NormalizeVector(fTargetNormal, fTargetNormal);
		
		// Make sure the normal is facing the player.
		new Float:fDirectionToPlayer[3];
		MakeVectorFromPoints(fUnsnappedTarget, fClientPosition, fDirectionToPlayer);
		NormalizeVector(fDirectionToPlayer, fDirectionToPlayer);
		if(GetVectorDotProduct(fDirectionToPlayer, fTargetNormal) < 0)
			NegateVector(fTargetNormal);
		
		// Snap the point to the grid, if the user wants it.
		SnapToGrid(client, fUnsnappedTarget, fTarget, fTargetNormal);
		
		MakeVectorFromPoints(fClientPosition, fTarget, fAimDirection);
		
		// Player is aiming at something that's nearer than the current maximal distance?
		new Float:fDistance = GetVectorLength(fAimDirection);
		if (fDistance <= g_ClientMenuState[client][CMS_aimCapDistance]
		// Or is currently adjusting the max distance and never set it before? Start moving the point at the current position.
		|| (bIsAdjustingAimLimit && g_ClientMenuState[client][CMS_aimCapDistance] < 0.0))
		{
			// Keep the aim cap distance at the distance of the nearest object, if currently adjusting it.
			if (bIsAdjustingAimLimit)
			{
				g_ClientMenuState[client][CMS_aimCapDistance] = fDistance;
			}
			return true;
		}
	}
	
	// See if we want to cap it at some distance.
	if (g_ClientMenuState[client][CMS_aimCapDistance] < 0.0)
		return bDidHit;
	
	// The traced point is further away than our limit.
	// Move |aimCapDistance| into the direction where the player is looking.
	GetAngleVectors(fClientAngles, fAimDirection, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(fAimDirection, fAimDirection);
	ScaleVector(fAimDirection, g_ClientMenuState[client][CMS_aimCapDistance]);
	AddVectors(fClientPosition, fAimDirection, fUnsnappedTarget);

	SnapToGrid(client, fUnsnappedTarget, fTarget, fTargetNormal);
	
	return true;
}

// Get ground position and normal for the position the player is standing on.
bool:GetClientFeetPosition(client, Float:fFeetPosition[3], Float:fGroundNormal[3])
{
	new Float:fOrigin[3];
	GetClientAbsOrigin(client, fOrigin);
	fFeetPosition = fOrigin;
	
	// Trace directly downwards
	fOrigin[2] += 16.0;
	TR_TraceRayFilter(fOrigin, Float:{90.0,0.0,0.0}, MASK_PLAYERSOLID, RayType_Infinite, RayFilter_DontHitPlayers);
	if (TR_DidHit())
	{
		TR_GetEndPosition(fOrigin);
		TR_GetPlaneNormal(INVALID_HANDLE, fGroundNormal);
		NormalizeVector(fGroundNormal, fGroundNormal);
		
		// Make sure the normal is facing the player.
		new Float:fDirectionToPlayer[3];
		MakeVectorFromPoints(fOrigin, fFeetPosition, fDirectionToPlayer);
		NormalizeVector(fDirectionToPlayer, fDirectionToPlayer);
		if(GetVectorDotProduct(fDirectionToPlayer, fGroundNormal) < 0)
			NegateVector(fGroundNormal);
		
		return true;
	}
	return false;
}

SnapToGrid(client, Float:fPoint[3], Float:fSnappedPoint[3], Float:fTargetNormal[3])
{
	// User has this disabled.
	if(!g_ClientMenuState[client][CMS_snapToGrid])
	{
		fSnappedPoint = fPoint;
		return;
	}
		
	new Float:fStepsize = g_fStepsizes[g_ClientMenuState[client][CMS_stepSizeIndex]];
	for(new i=0; i<3; i++)
	{
		fSnappedPoint[i] = RoundToNearest(fPoint[i] / fStepsize) * fStepsize;
	}
	
	// Snap to walls!
	// See if the grid snapped behind the target point.
	if (!Math_VectorsEqual(fTargetNormal, Float:{0.0,0.0,0.0}))
	{
		new Float:fSnappedDirection[3];
		MakeVectorFromPoints(fPoint, fSnappedPoint, fSnappedDirection);
		NormalizeVector(fSnappedDirection, fSnappedDirection);
		// The grid point is behind the end position. Bring it forward again.
		if (GetVectorDotProduct(fTargetNormal, fSnappedDirection) < 0.0)
		{
			// Trace back to the wall.
			if(Math_GetLinePlaneIntersection(fSnappedPoint, fTargetNormal, fPoint, fTargetNormal, fSnappedPoint))
			{
				// And a bit further.
				ScaleVector(fTargetNormal, 0.01);
				AddVectors(fSnappedPoint, fTargetNormal, fSnappedPoint);
			}
		}
		
		new bool:bChanged;
		do
		{
			bChanged = false;
			// See if we're still behind some other wall after moving the point toward the normal again.
			new Float:fAngles[3];
			MakeVectorFromPoints(fPoint, fSnappedPoint, fSnappedDirection);
			NormalizeVector(fSnappedDirection, fSnappedDirection);
			GetVectorAngles(fSnappedDirection, fAngles);
			
			TR_TraceRayFilter(fPoint, fAngles, MASK_PLAYERSOLID, RayType_Infinite, RayFilter_DontHitPlayers);
			if (!TR_DidHit())
				return;
			
			new Float:fOtherWall[3], Float:fOtherWallDirection[3];
			TR_GetEndPosition(fOtherWall);
			MakeVectorFromPoints(fOtherWall, fSnappedPoint, fOtherWallDirection);
			NormalizeVector(fOtherWallDirection, fOtherWallDirection);
			
			TR_GetPlaneNormal(INVALID_HANDLE, fTargetNormal);
			NormalizeVector(fTargetNormal, fTargetNormal);
			
			// Make sure the normal is facing the player.
			new Float:fDirectionToPlayer[3];
			MakeVectorFromPoints(fOtherWall, fPoint, fDirectionToPlayer);
			NormalizeVector(fDirectionToPlayer, fDirectionToPlayer);
			if(GetVectorDotProduct(fDirectionToPlayer, fTargetNormal) < 0)
				NegateVector(fTargetNormal);
			
			// The grid point is behind some other wall too.
			if (GetVectorDotProduct(fTargetNormal, fOtherWallDirection) < 0.0)
			{
				// Trace back to the wall.
				if (Math_GetLinePlaneIntersection(fSnappedPoint, fTargetNormal, fOtherWall, fTargetNormal, fSnappedPoint))
				{
					// And a bit further.
					ScaleVector(fTargetNormal, 0.01);
					AddVectors(fSnappedPoint, fTargetNormal, fSnappedPoint);
					bChanged = true;
				}
			}
		}
		while (bChanged);
	}
}

bool:Math_GetLinePlaneIntersection(Float:fLinePoint[3], Float:fLineDirection[3], Float:fPlanePoint[3], Float:fPlaneNormal[3], Float:fCollisionPoint[3])
{
	new Float:fCos = GetVectorDotProduct(fLineDirection, fPlaneNormal);
	// Line is parallel to the plane. No single intersection point.
	if (fCos == 0.0)
		return false;
	
	new Float:fTowardsPlane[3];
	SubtractVectors(fPlanePoint, fLinePoint, fTowardsPlane);
	
	new Float:fDistance = GetVectorDotProduct(fTowardsPlane, fPlaneNormal) / fCos;
	new Float:fMoveOnLine[3];
	fMoveOnLine = fLineDirection;
	ScaleVector(fMoveOnLine, fDistance);
	AddVectors(fLinePoint, fMoveOnLine, fCollisionPoint);
	return true;
}

// Handle the default height of a zone when it's too flat.
HandleZoneDefaultHeight(&Float:fFirstPointZ, &Float:fSecondPointZ)
{
	new Float:fDefaultHeight = GetConVarFloat(g_hCVDefaultHeight);
	if (fDefaultHeight == 0.0)
		return;
	
	new Float:fMinHeight = GetConVarFloat(g_hCVMinHeight);
	new Float:fZoneHeight = FloatAbs(fFirstPointZ - fSecondPointZ);
	if (fZoneHeight > fMinHeight)
		return;
	
	// See which point is higher, so we can raise it even more.
	if (fFirstPointZ > fSecondPointZ)
	{
		fFirstPointZ += fDefaultHeight - fZoneHeight;
	}
	else
	{
		fSecondPointZ += fDefaultHeight - fZoneHeight;
	}
}

ResetZoneAddingState(client)
{
	g_ClientMenuState[client][CMS_addZone] = false;
	g_ClientMenuState[client][CMS_editState] = ZES_first;
	Array_Fill(g_ClientMenuState[client][CMS_first], 3, 0.0);
	Array_Fill(g_ClientMenuState[client][CMS_second], 3, 0.0);
	ClearHandle(g_hShowZoneWhileEditTimer[client]);
}

SaveNewZone(client, const String:sName[])
{
	if(!g_ClientMenuState[client][CMS_addZone])
		return;

	new group[ZoneGroup], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	if(g_ClientMenuState[client][CMS_cluster] != -1)
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
	
	new zoneData[ZoneData];
	strcopy(zoneData[ZD_name], MAX_ZONE_NAME, sName);
	
	SaveChangedZoneCoordinates(client, zoneData);
	
	// Save the zone in this group.
	zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
	zoneData[ZD_clusterIndex] = g_ClientMenuState[client][CMS_cluster];
	
	// Display it right away?
	if(zoneData[ZD_clusterIndex] == -1)
		zoneData[ZD_adminShowZone][client] = group[ZG_adminShowZones][client];
	else
		zoneData[ZD_adminShowZone][client] = zoneCluster[ZC_adminShowZones][client];
	
	// Don't use a seperate color for this zone.
	zoneData[ZD_color][0] = -1;
	
	zoneData[ZD_index] = GetArraySize(group[ZG_zones]);
	PushArrayArray(group[ZG_zones], zoneData[0], _:ZoneData);
	
	if(zoneData[ZD_clusterIndex] == -1)
	{
		PrintToChat(client, "Map Zones > Added new zone \"%s\" to group \"%s\".", sName, group[ZG_name]);
		LogAction(client, -1, "%L created a new zone in group \"%s\" called \"%s\" at [%f,%f,%f]", client, group[ZG_name], zoneData[ZD_name], zoneData[ZD_position][0], zoneData[ZD_position][1], zoneData[ZD_position][2]);
	}
	else
	{
		PrintToChat(client, "Map Zones > Added new zone \"%s\" to cluster \"%s\" in group \"%s\".", sName, zoneCluster[ZC_name], group[ZG_name]);
		LogAction(client, -1, "%L created a new zone in cluster \"%s\" of group \"%s\" called \"%s\" at [%f,%f,%f]", client, zoneCluster[ZC_name], group[ZG_name], zoneData[ZD_name], zoneData[ZD_position][0], zoneData[ZD_position][1], zoneData[ZD_position][2]);
	}
	ResetZoneAddingState(client);
	
	// Create the trigger.
	if(!SetupZone(group, zoneData))
		PrintToChat(client, "Map Zones > Error creating trigger for new zone.");
	
	// Edit the new zone right away.
	g_ClientMenuState[client][CMS_zone] = zoneData[ZD_index];
	
	// If we just pasted this zone, we want to edit the center position right away!
	if(g_ClientMenuState[client][CMS_editCenter])
		DisplayZonePointEditMenu(client);
	else
		DisplayZoneEditMenu(client);
}

SaveChangedZoneCoordinates(client, zoneData[ZoneData])
{
	new Float:fMins[3], Float:fMaxs[3], Float:fPosition[3], Float:fAngles[3];
	Array_Copy(g_ClientMenuState[client][CMS_rotation], fAngles, 3);
	Array_Copy(g_ClientMenuState[client][CMS_first], fMins, 3);
	Array_Copy(g_ClientMenuState[client][CMS_second], fMaxs, 3);
	
	new Float:fOldMins[3];
	// Apply the rotation so we find the right middle, if there is rotation already.
	if(!Math_VectorsEqual(fAngles, Float:{0.0,0.0,0.0}))
	{
		Array_Copy(zoneData[ZD_position], fPosition, 3);
		SubtractVectors(fMins, fPosition, fMins);
		SubtractVectors(fMaxs, fPosition, fMaxs);
		Math_RotateVector(fMins, fAngles, fMins);
		Math_RotateVector(fMaxs, fAngles, fMaxs);
		AddVectors(fMins, fPosition, fMins);
		AddVectors(fMaxs, fPosition, fMaxs);
		
		Vector_GetMiddleBetweenPoints(fMins, fMaxs, fPosition);
		
		fOldMins = fMins;
		Array_Copy(g_ClientMenuState[client][CMS_first], fMins, 3);
		Array_Copy(g_ClientMenuState[client][CMS_second], fMaxs, 3);
	}
	else
	{
		// Have the trigger's bounding box be centered.
		Vector_GetMiddleBetweenPoints(fMins, fMaxs, fPosition);
	}
	
	// Center mins and maxs around the root [0,0,0].
	SubtractVectors(fMins, fPosition, fMins);
	SubtractVectors(fMaxs, fPosition, fMaxs);
	
	// Make sure the mins are lower than the maxs.
	for(new i=0;i<3;i++)
	{
		if(fMins[i] > 0.0)
			fMins[i] *= -1.0;
		if(fMaxs[i] < 0.0)
			fMaxs[i] *= -1.0;
	}
	
	Array_Copy(fMins, zoneData[ZD_mins], 3);
	Array_Copy(fMaxs, zoneData[ZD_maxs], 3);
	
	// Find the correct new middle position if the box has been rotated.
	// We changed the mins/maxs relative to the rotated middle position..
	// Get the new center position which is the correct center after rotation was applied.
	// XXX: There might be an easier way?
	if(!Math_VectorsEqual(fAngles, Float:{0.0,0.0,0.0}))
	{
		Math_RotateVector(fMins, fAngles, fMins);
		AddVectors(fMins, fPosition, fMins);
		SubtractVectors(fOldMins, fMins, fOldMins);
		ScaleVector(fAngles, -1.0);
		Math_RotateVector(fOldMins, fAngles, fOldMins);
		AddVectors(fPosition, fOldMins, fPosition);
	}
	Array_Copy(fPosition, zoneData[ZD_position], 3);
}

GetFreeAutoZoneName(group[ZoneGroup], String:sBuffer[], maxlen)
{
	new iIndex = 1;
	do
	{
		Format(sBuffer, maxlen, "Zone %d", iIndex++);
	} while(ZoneExistsWithName(group, sBuffer));
}

/**
 * Clipboard helpers
 */
ClearClientClipboard(client)
{
	Array_Fill(g_Clipboard[client][CB_mins], 3, 0.0);
	Array_Fill(g_Clipboard[client][CB_maxs], 3, 0.0);
	Array_Fill(g_Clipboard[client][CB_position], 3, 0.0);
	Array_Fill(g_Clipboard[client][CB_rotation], 3, 0.0);
	g_Clipboard[client][CB_name][0] = '\0';
}

SaveToClipboard(client, zoneData[ZoneData])
{
	Array_Copy(zoneData[ZD_mins], g_Clipboard[client][CB_mins], 3);
	Array_Copy(zoneData[ZD_maxs], g_Clipboard[client][CB_maxs], 3);
	Array_Copy(zoneData[ZD_position], g_Clipboard[client][CB_position], 3);
	Array_Copy(zoneData[ZD_rotation], g_Clipboard[client][CB_rotation], 3);
	strcopy(g_Clipboard[client][CB_name], MAX_ZONE_NAME, zoneData[ZD_name]);
}

PasteFromClipboard(client)
{
	// We want to edit the center position directly afterwards
	g_ClientMenuState[client][CMS_editCenter] = true;
	// But first we have to add the zone to the current group and give it a new name.
	g_ClientMenuState[client][CMS_addZone] = true;
	g_ClientMenuState[client][CMS_editState] = ZES_name;
	
	// Copy the details to the client state.
	for(new i=0;i<3;i++)
	{
		g_ClientMenuState[client][CMS_first][i] = g_Clipboard[client][CB_position][i] + g_Clipboard[client][CB_mins][i];
		g_ClientMenuState[client][CMS_second][i] = g_Clipboard[client][CB_position][i] + g_Clipboard[client][CB_maxs][i];
		g_ClientMenuState[client][CMS_rotation][i] = g_Clipboard[client][CB_rotation][i];
		g_ClientMenuState[client][CMS_center][i] = g_Clipboard[client][CB_position][i];
	}
	
	PrintToChat(client, "Map Zones > Please type a new name for this new copy of zone \"%s\" in chat. Type \"!abort\" to abort.", g_Clipboard[client][CB_name]);
	DisplayZoneAddFinalizationMenu(client);
}

bool:HasZoneInClipboard(client)
{
	return g_Clipboard[client][CB_name][0] != '\0';
}

/**
 * Generic helpers
 */
bool:ExtractIndicesFromString(const String:sTargetName[], &iGroupIndex, &iZoneIndex)
{
	new String:sBuffer[64];
	strcopy(sBuffer, sizeof(sBuffer), sTargetName);

	// Has to start with "mapzonelib_"
	if(StrContains(sBuffer, "mapzonelib_") != 0)
		return false;
	
	ReplaceString(sBuffer, sizeof(sBuffer), "mapzonelib_", "");
	
	new iLen = strlen(sBuffer);
	
	// Extract the group and zone indicies from the targetname.
	new iUnderscorePos = FindCharInString(sBuffer, '_');
	
	// Zone index missing?
	if(iUnderscorePos+1 >= iLen)
		return false;
	
	iZoneIndex = StringToInt(sBuffer[iUnderscorePos+1]);
	sBuffer[iUnderscorePos] = 0;
	iGroupIndex = StringToInt(sBuffer);
	return true;
}

Vector_GetMiddleBetweenPoints(const Float:vec1[3], const Float:vec2[3], Float:result[3])
{
	new Float:mid[3];
	MakeVectorFromPoints(vec1, vec2, mid);
	mid[0] = mid[0] / 2.0;
	mid[1] = mid[1] / 2.0;
	mid[2] = mid[2] / 2.0;
	AddVectors(vec1, mid, result);
}

public bool:RayFilter_DontHitSelf(entity, contentsMask, any:data)
{
	return entity != data;
}

public bool:RayFilter_DontHitPlayers(entity, contentsMask, any:data)
{
	return entity < 1 && entity > MaxClients;
}
