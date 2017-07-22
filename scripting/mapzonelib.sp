#pragma semicolon 1
#include <sourcemod>
#include <mapzonelib>
#include <smlib>
#pragma newdecls required

#define PLUGIN_VERSION "1.0"

#define XYZ(%1) %1[0], %1[1], %1[2]

enum ZoneData {
	ZD_index,
	ZD_databaseId,
	ZD_triggerEntity,
	ZD_clusterIndex,
	ZD_teamFilter,
	ZD_color[4],
	bool:ZD_customKVChanged, // Remember when the custom keyvalues were changed, so we sync the database.
	StringMap:ZD_customKV,
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
	ZC_databaseId,
	bool:ZC_deleted,
	ZC_teamFilter,
	ZC_color[4],
	bool:ZC_customKVChanged, // Remember when the custom keyvalues were changed, so we sync the database.
	StringMap:ZC_customKV,
	bool:ZC_adminShowZones[MAXPLAYERS+1],  // Just to remember if we want to toggle all zones in this cluster on or off.
	ZC_clientInZones[MAXPLAYERS+1], // Save for each player in how many zones of this cluster he is.
	String:ZC_name[MAX_ZONE_NAME]
};

enum ZoneGroup {
	ZG_index,
	ArrayList:ZG_zones,
	ArrayList:ZG_cluster,
	Handle:ZG_menuCancelForward,
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
float g_fStepsizes[] = {1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0};

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
	String:CMS_presetZoneName[MAX_ZONE_NAME], // When adding a zone through the MapZone_StartAddingZone native, a name can be passed with it.
	bool:CMS_backToMenuAfterEdit, // Call the menuCancel forward of the group after editing or adding a zone.
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

ConVar g_hCVShowZonesDefault;
ConVar g_hCVOptimizeBeams;
ConVar g_hCVDebugBeamDistance;
ConVar g_hCVMinHeight;
ConVar g_hCVDefaultHeight;
ConVar g_hCVDefaultSnapToGrid;
ConVar g_hCVPlayerCenterCollision;

ConVar g_hCVDatabaseConfig;
ConVar g_hCVTablePrefix;

Handle g_hfwdOnEnterForward;
Handle g_hfwdOnLeaveForward;
Handle g_hfwdOnCreatedForward;
Handle g_hfwdOnRemovedForward;
Handle g_hfwdOnAddedToClusterForward;
Handle g_hfwdOnRemovedFromClusterForward;

// Displaying of zones using laser beams
Handle g_hShowZonesTimer;
int g_iLaserMaterial = -1;
int g_iHaloMaterial = -1;
int g_iGlowSprite = -1;

// Central array to save all information about zones
ArrayList g_hZoneGroups;

// Optional database connection
Database g_hDatabase;
char g_sTablePrefix[64];
char g_sCurrentMap[128];
bool g_bConnectingToDatabase;
// Used to discard old requests when changing the map fast.
int g_iDatabaseSequence;

// Support for browsing through nested menus
int g_ClientMenuState[MAXPLAYERS+1][ClientMenuState];
// Copy & paste zones even over different groups.
int g_Clipboard[MAXPLAYERS+1][ClientClipBoard];
// Show the crosshair and current zone while adding/editing a zone.
Handle g_hShowZoneWhileEditTimer[MAXPLAYERS+1];
// Temporary store the angles the player looked at when starting 
// to press +attack2 to keep the view and laser point steady.
float g_fAimCapTempAngles[MAXPLAYERS+1][3];
// Store the buttons the player pressed in the previous frame, so we know when he started to press something.
int g_iClientButtons[MAXPLAYERS+1];

public Plugin myinfo = 
{
	name = "Map Zone Library",
	author = "Peace-Maker",
	description = "Manages zones on maps and fires forwards, when players enter or leave the zone.",
	version = PLUGIN_VERSION,
	url = "https://www.wcfan.de/"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("MapZone_RegisterZoneGroup", Native_RegisterZoneGroup);
	CreateNative("MapZone_ShowMenu", Native_ShowMenu);
	CreateNative("MapZone_ShowZoneEditMenu", Native_ShowZoneEditMenu);
	CreateNative("MapZone_SetMenuCancelAction", Native_SetMenuCancelAction);
	CreateNative("MapZone_StartAddingZone", Native_StartAddingZone);
	CreateNative("MapZone_AddCluster", Native_AddCluster);
	CreateNative("MapZone_SetZoneDefaultColor", Native_SetZoneDefaultColor);
	CreateNative("MapZone_SetZoneColor", Native_SetZoneColor);
	CreateNative("MapZone_SetClientZoneVisibility", Native_SetClientZoneVisibility);
	CreateNative("MapZone_ZoneExists", Native_ZoneExists);
	CreateNative("MapZone_GetZoneIndex", Native_GetZoneIndex);
	CreateNative("MapZone_GetZoneNameByIndex", Native_GetZoneNameByIndex);
	CreateNative("MapZone_GetGroupZones", Native_GetGroupZones);
	CreateNative("MapZone_GetZoneType", Native_GetZoneType);
	CreateNative("MapZone_GetClusterZones", Native_GetClusterZones);
	CreateNative("MapZone_GetClusterNameOfZone", Native_GetClusterNameOfZone);
	CreateNative("MapZone_SetZoneName", Native_SetZoneName);
	CreateNative("MapZone_GetZonePosition", Native_GetZonePosition);
	CreateNative("MapZone_GetCustomString", Native_GetCustomString);
	CreateNative("MapZone_SetCustomString", Native_SetCustomString);
	RegPluginLibrary("mapzonelib");
	return APLRes_Success;
}

public void OnPluginStart()
{
	// forward MapZone_OnClientEnterZone(client, const String:sZoneGroup[], const String:sZoneName[]);
	g_hfwdOnEnterForward = CreateGlobalForward("MapZone_OnClientEnterZone", ET_Ignore, Param_Cell, Param_String, Param_String);
	// forward MapZone_OnClientLeaveZone(client, const String:sZoneGroup[], const String:sZoneName[]);
	g_hfwdOnLeaveForward = CreateGlobalForward("MapZone_OnClientLeaveZone", ET_Ignore, Param_Cell, Param_String, Param_String);
	// forward MapZone_OnZoneCreated(const String:sZoneGroup[], const String:sZoneName[], ZoneType:type, iCreator);
	g_hfwdOnCreatedForward = CreateGlobalForward("MapZone_OnZoneCreated", ET_Ignore, Param_String, Param_String, Param_Cell, Param_Cell);
	// forward MapZone_OnZoneRemoved(const String:sZoneGroup[], const String:sZoneName[], ZoneType:type, iRemover);
	g_hfwdOnRemovedForward = CreateGlobalForward("MapZone_OnZoneRemoved", ET_Ignore, Param_String, Param_String, Param_Cell, Param_Cell);
	// forward MapZone_OnZoneAddedToCluster(const String:sZoneGroup[], const String:sZoneName[], const String:sClusterName[], iAdmin);
	g_hfwdOnAddedToClusterForward = CreateGlobalForward("MapZone_OnZoneAddedToCluster", ET_Ignore, Param_String, Param_String, Param_String, Param_Cell);
	// forward MapZone_OnZoneRemovedFromCluster(const String:sZoneGroup[], const String:sZoneName[], const String:sClusterName[], iAdmin);
	g_hfwdOnRemovedFromClusterForward = CreateGlobalForward("MapZone_OnZoneRemovedFromCluster", ET_Ignore, Param_String, Param_String, Param_String, Param_Cell);
	g_hZoneGroups = new ArrayList(view_as<int>(ZoneGroup));
	
	LoadTranslations("common.phrases");
	
	g_hCVShowZonesDefault = CreateConVar("sm_mapzone_showzones", "0", "Show all zones to all players by default?", _, true, 0.0, true, 1.0);
	g_hCVOptimizeBeams = CreateConVar("sm_mapzone_optimize_beams", "1", "Try to hide zones from players, that aren't able to see them?", _, true, 0.0, true, 1.0);
	g_hCVDebugBeamDistance = CreateConVar("sm_mapzone_debug_beamdistance", "5000", "Only show zones that are as close as up to x units to the player.", _, true, 0.0);
	g_hCVMinHeight = CreateConVar("sm_mapzone_minheight", "10", "Snap to the default_height if zone is below this height.", _, true, 0.0);
	g_hCVDefaultHeight = CreateConVar("sm_mapzone_default_height", "128", "The default height of a zone when it's below the minimum height. 0 to disable.", _, true, 0.0);
	g_hCVDefaultSnapToGrid = CreateConVar("sm_mapzone_default_snaptogrid_enabled", "0", "Enable snapping to map grid by default?", _, true, 0.0, true, 1.0);
	g_hCVPlayerCenterCollision = CreateConVar("sm_mapzone_player_center_trigger", "0", "Shrink the zone trigger by half the size of a player model to make it look like the center of the player has to be in a zone to make him register as being in it?", _, true, 0.0, true, 1.0);
	g_hCVDatabaseConfig = CreateConVar("sm_mapzone_database_config", "", "The database section in databases.cfg to connect to. Optionally save and load zones from that database. Only used when this option is set. Will still save the zones to local files too as backup if database is unavailable.");
	g_hCVTablePrefix = CreateConVar("sm_mapzone_database_prefix", "zones_", "Optional prefix of the database tables. e.g. \"zone_\"");
	
	AutoExecConfig(true, "plugin.mapzonelib");
	
	g_hCVShowZonesDefault.AddChangeHook(ConVar_OnDebugChanged);
	g_hCVPlayerCenterCollision.AddChangeHook(ConVar_OnPlayerCenterCollisionChanged);
	
	HookEvent("round_start", Event_OnRoundStart);
	HookEvent("player_spawn", Event_OnPlayerSpawn);
	HookEvent("player_death", Event_OnPlayerDeath);
	
	// Clear menu states
	for(int i=1;i<=MaxClients;i++)
		OnClientDisconnect(i);
}

public void OnPluginEnd()
{
	// Map might not be loaded anymore on server shutdown.
	// Don't create a ".zones" file. OnMapEnd would have been called before, 
	// so the zones are saved.
	char sMap[32];
	if (!GetCurrentMap(sMap, sizeof(sMap)))
		return;
	
	SaveAllZoneGroups();
	
	// Kill all created trigger_multiple.
	int iNumGroups = g_hZoneGroups.Length;
	int iNumZones, group[ZoneGroup], zoneData[ZoneData];
	for(int i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		iNumZones = group[ZG_zones].Length;
		for(int c=0;c<iNumZones;c++)
		{
			GetZoneByIndex(c, group, zoneData);
			RemoveZoneTrigger(group, zoneData);
		}
	}
}

/**
 * Core forward callbacks
 */
public void OnConfigsExecuted()
{
	char sDatabase[256];
	g_hCVDatabaseConfig.GetString(sDatabase, sizeof(sDatabase));
	g_hCVTablePrefix.GetString(g_sTablePrefix, sizeof(g_sTablePrefix));
	
	// Remove all zones of the old map
	ClearZonesInGroups();
	
	// Storing zones in a database is optional. Nothing to do here when the option is not set.
	if (!sDatabase[0])
	{
		// Load the zones from the config files.
		LoadAllGroupZones();
		// Spawn the trigger_multiples for all zones
		SetupAllGroupZones();
		return;
	}
	
	// Load all zones for the current map for all registered groups
	if (g_hDatabase)
	{
		 // Use sequence number in queries to discard late results when changing map quickly.
		LoadAllGroupZonesFromDatabase(++g_iDatabaseSequence);
	}
	// Not already in the process of connecting.
	else if (!g_bConnectingToDatabase)
	{
		g_bConnectingToDatabase = true;
		Database.Connect(SQL_OnConnect, sDatabase);
	}
}

public void OnMapStart()
{
	PrecacheModel("models/error.mdl", true);

	// Don't want to redefine the default sprites.
	// Borrow them for different games from sm's default funcommands plugin.
	Handle hGameConfig = LoadGameConfigFile("funcommands.games");
	if (!hGameConfig)
	{
		SetFailState("Unable to load game config funcommands.games from stock sourcemod plugin for beam materials.");
		return;
	}
	
	GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));
	
	char sBuffer[PLATFORM_MAX_PATH];
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
	
	delete hGameConfig;
	
	// Remove all zones of the old map
	ClearZonesInGroups();
	
	g_hShowZonesTimer = CreateTimer(2.0, Timer_ShowZones, _, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
}

public void OnMapEnd()
{
	SaveAllZoneGroups();
	g_hShowZonesTimer = null;
}

public void OnClientDisconnect(int client)
{
	g_ClientMenuState[client][CMS_group] = -1;
	g_ClientMenuState[client][CMS_cluster] = -1;
	g_ClientMenuState[client][CMS_zone] = -1;
	g_ClientMenuState[client][CMS_rename] = false;
	g_ClientMenuState[client][CMS_addCluster] = false;
	g_ClientMenuState[client][CMS_editRotation] = false;
	g_ClientMenuState[client][CMS_editCenter] = false;
	g_ClientMenuState[client][CMS_editPosition] = false;
	g_ClientMenuState[client][CMS_backToMenuAfterEdit] = false;
	g_ClientMenuState[client][CMS_previewMode] = ZPM_aim;
	g_ClientMenuState[client][CMS_disablePreview] = false;
	g_ClientMenuState[client][CMS_stepSizeIndex] = DEFAULT_STEPSIZE_INDEX;
	g_ClientMenuState[client][CMS_aimCapDistance] = -1.0;
	g_ClientMenuState[client][CMS_redrawPointMenu] = false;
	g_ClientMenuState[client][CMS_snapToGrid] = g_hCVDefaultSnapToGrid.BoolValue;
	Array_Fill(g_ClientMenuState[client][CMS_rotation], 3, 0.0);
	Array_Fill(g_ClientMenuState[client][CMS_center], 3, 0.0);
	ResetZoneAddingState(client);
	g_iClientButtons[client] = 0;
	
	ClearClientClipboard(client);
	
	// If he was in some zone, guarantee to call the leave callback.
	RemoveClientFromAllZones(client);
	
	int iNumGroups = g_hZoneGroups.Length;
	int iNumClusters, iNumZones;
	int group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
	for(int i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		group[ZG_adminShowZones][client] = false;
		SaveGroup(group);
		
		iNumZones = group[ZG_cluster].Length;
		for(int z=0;z<iNumZones;z++)
		{
			GetZoneByIndex(z, group, zoneData);
			// Doesn't want to see zones anymore.
			zoneData[ZD_adminShowZone][client] = false;
			SaveZone(group, zoneData);
		}
		
		// Client is no longer in any clusters.
		// Just to make sure.
		iNumClusters = group[ZG_cluster].Length;
		for(int c=0;c<iNumClusters;c++)
		{
			GetZoneClusterByIndex(c, group, zoneCluster);
			zoneCluster[ZC_clientInZones][client] = 0;
			zoneCluster[ZC_adminShowZones][client] = false;
			SaveCluster(group, zoneCluster);
		}
	}
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if(g_ClientMenuState[client][CMS_rename])
	{
		g_ClientMenuState[client][CMS_rename] = false;
	
		int group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		
		if(g_ClientMenuState[client][CMS_zone] != -1)
		{
			int zoneData[ZoneData];
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
			int zoneCluster[ZoneCluster];
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
		int group[ZoneGroup];
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
		bool bIsEditingZone = g_ClientMenuState[client][CMS_zone] != -1;
		
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
		
		int group[ZoneGroup];
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
		
		int zoneCluster[ZoneCluster];
		AddNewCluster(group, sArgs, zoneCluster);
		PrintToChat(client, "Map Zones > Added new cluster \"%s\".", zoneCluster[ZC_name]);
		
		// Add the currently edited zone to the new cluster right away.
		if (bIsEditingZone)
		{
			int zoneData[ZoneData];
			GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);

			PrintToChat(client, "Map Zones > Zone \"%s\" is now part of cluster \"%s\".", zoneData[ZD_name], zoneCluster[ZC_name]);
		
			zoneData[ZD_clusterIndex] = zoneCluster[ZC_index];
			SaveZone(group, zoneData);
			
			// Inform other plugins.
			CallOnAddedToCluster(group, zoneData, zoneCluster, client);
			
			DisplayZoneEditMenu(client);
		}
		else
		{
			g_ClientMenuState[client][CMS_cluster] = zoneCluster[ZC_index];
			DisplayClusterEditMenu(client);
		}
		
		// Inform other plugins that this cluster is now a thing.
		CallOnClusterCreated(group, zoneCluster, client);
		
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	static int s_tickinterval[MAXPLAYERS+1];
	
	// Client is currently editing or adding a zone point.
	int iRemoveButtons;
	if (IsClientEditingZonePosition(client) && !g_ClientMenuState[client][CMS_disablePreview])
	{
		// Started pressing +use
		// See if he wants to set a zone's position.
		if(buttons & IN_USE && !(g_iClientButtons[client] & IN_USE))
		{
			float fUnsnappedOrigin[3], fSnappedOrigin[3], fGroundNormal[3];
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
			float fAimPosition[3], fUnsnappedAimPosition[3];
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
			float fAngles[3];
			GetClientEyeAngles(client, fAngles);
			
			// Only display the laser bbox, if the player moved his mouse.
			bool bChanged;
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
				int group[ZoneGroup], zoneData[ZoneData];
				GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
				GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
				
				float fPos[3], fMins[3], fMaxs[3];
				Array_Copy(zoneData[ZD_position], fPos, 3);
				Array_Copy(zoneData[ZD_mins], fMins, 3);
				Array_Copy(zoneData[ZD_maxs], fMaxs, 3);
				Array_Copy(g_ClientMenuState[client][CMS_rotation], fAngles, 3);
				
				Effect_DrawBeamBoxRotatableToClient(client, fPos, fMins, fMaxs, fAngles, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 2.0, 2.0, 2, 1.0, {0,0,255,255}, 0);
				Effect_DrawAxisOfRotationToClient(client, fPos, fAngles, view_as<float>({20.0,20.0,20.0}), g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 2.0, 2.0, 2, 1.0, 0);
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

public void ConVar_OnDebugChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	bool bShowZones = g_hCVShowZonesDefault.BoolValue;
	int iSize = g_hZoneGroups.Length;
	int group[ZoneGroup];
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		group[ZG_showZones] = bShowZones;
		SaveGroup(group);
	}
	
	// Show all zones immediately!
	if(bShowZones)
		TriggerTimer(g_hShowZonesTimer, true);
}

public void ConVar_OnPlayerCenterCollisionChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	// Update all triggers with the changed bounds reduction right away.
	int iNumGroups = g_hZoneGroups.Length;
	int iNumZones, group[ZoneGroup], zoneData[ZoneData];
	for(int i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		iNumZones = group[ZG_zones].Length;
		for(int z=0;z<iNumZones;z++)
		{
			GetZoneByIndex(z, group, zoneData);
			if(zoneData[ZD_deleted])
				continue;

			ApplyNewTriggerBounds(zoneData);
		}
	}
}

/**
 * Event callbacks
 */
public void Event_OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	SetupAllGroupZones();
}

public void Event_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!client)
		return;
	
	// Check if the players are in one of the zones
	// THIS IS HORRBILE, but the engine doesn't really spawn players on round_start
	// if they were alive at the end of the previous round (at least in CS:S),
	// so collision checks with triggers aren't run.
	// Have them fire the leave callback on all zones they were in before respawning
	// and have the "OnTrigger" output pickup the new touch.
	int iNumGroups = g_hZoneGroups.Length;
	int iNumZones, group[ZoneGroup], zoneData[ZoneData];
	int iTrigger;
	for(int i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		iNumZones = group[ZG_zones].Length;
		for(int z=0;z<iNumZones;z++)
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

public void Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!client)
		return;
	
	// Dead players are in no zones anymore.
	RemoveClientFromAllZones(client);
}

/**
 * Native callbacks
 */
// native void MapZone_RegisterZoneGroup(const char[] group);
public int Native_RegisterZoneGroup(Handle plugin, int numParams)
{
	char sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	
	int group[ZoneGroup];
	// See if there already is a group with that name
	if(GetGroupByName(sName, group))
	{
		// Call the creation forwards again for all the zones as if they were just loaded.
		CallOnCreatedForAllInGroup(group);
		return;
	}
	
	strcopy(group[ZG_name][0], MAX_ZONE_GROUP_NAME, sName);
	group[ZG_zones] = new ArrayList(view_as<int>(ZoneData));
	group[ZG_cluster] = new ArrayList(view_as<int>(ZoneCluster));
	group[ZG_showZones] = g_hCVShowZonesDefault.BoolValue;
	group[ZG_menuCancelForward] = INVALID_HANDLE;
	group[ZG_filterEntTeam][0] = INVALID_ENT_REFERENCE;
	group[ZG_filterEntTeam][1] = INVALID_ENT_REFERENCE;
	// Default to red color.
	group[ZG_defaultColor][0] = 255;
	group[ZG_defaultColor][3] = 255;
	group[ZG_index] = g_hZoneGroups.Length;
	g_hZoneGroups.PushArray(group[0], view_as<int>(ZoneGroup));
	
	// Load the zone details
	if (g_hDatabase)
		LoadZoneGroupFromDatabase(group, g_iDatabaseSequence);
	// If we're in the process of connecting to the database, don't do anything now.
	// The zones for this group will be loaded once the database connected.
	else if (!g_bConnectingToDatabase)
		LoadZoneGroup(group);
}

// bool MapZone_ShowMenu(int client, const char[] group);
public int Native_ShowMenu(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
		return false;
	}

	char sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(2, sName, sizeof(sName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return false;
	
	DisplayGroupRootMenu(client, group);
	return true;
}

// native void MapZone_ShowZoneEditMenu(int client, const char[] group, const char[] zoneName, bool bEnableCancelForward = false);
public int Native_ShowZoneEditMenu(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
		return;
	}

	char sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(2, sName, sizeof(sName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid map group name \"%s\"", sName);
		return;
	}
	
	bool bEnableCancelForward = view_as<bool>(GetNativeCell(3));
	
	// Show the right edit menu for that zone or cluster.
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(3, sZoneName, sizeof(sZoneName));
	int zoneCluster[ZoneCluster], zoneData[ZoneData];
	if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		g_ClientMenuState[client][CMS_group] = group[ZG_index];
		g_ClientMenuState[client][CMS_cluster] = zoneCluster[ZC_index];
		DisplayClusterEditMenu(client);
	}
	else if (GetZoneByName(sZoneName, group, zoneData))
	{
		g_ClientMenuState[client][CMS_group] = group[ZG_index];
		g_ClientMenuState[client][CMS_zone] = zoneData[ZD_index];
		DisplayZoneEditMenu(client);
	}
	else
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid zone or cluster name \"%s\"", sName);
		return;
	}
	
	g_ClientMenuState[client][CMS_backToMenuAfterEdit] = bEnableCancelForward;
}

// native bool MapZone_SetZoneDefaultColor(const char[] group, const int iColor[4]);
public int Native_SetZoneDefaultColor(Handle plugin, int numParams)
{
	char sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	
	int iColor[4];
	GetNativeArray(2, iColor, 4);
	
	int group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return false;
	
	Array_Copy(iColor, group[ZG_defaultColor], 4);
	SaveGroup(group);
	
	return true;
}

// native bool MapZone_SetZoneColor(const char[] group, const char[] zoneName, const int iColor[4]);
public int Native_SetZoneColor(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	int iColor[4];
	GetNativeArray(3, iColor, 4);
	
	// Find a matching cluster or zone.
	int zoneCluster[ZoneCluster], zoneData[ZoneData];
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

// native bool MapZone_SetClientZoneVisibility(const char[] group, const char[] zoneName, int client, bool bVisible);
public int Native_SetClientZoneVisibility(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	int client = GetNativeCell(3);
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
		return false;
	}
	
	bool bVisible = view_as<bool>(GetNativeCell(4));
	
	// Find a matching cluster or zone.
	int zoneCluster[ZoneCluster], zoneData[ZoneData];
	if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		zoneCluster[ZC_adminShowZones][client] = bVisible;
		SaveCluster(group, zoneCluster);
		
		// Set all zones of this cluster to the same state.
		int iNumZones = group[ZG_zones].Length;
		for(int i=0;i<iNumZones;i++)
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

// native bool MapZone_SetMenuCancelAction(const char[] group, MapZoneMenuCancelCB callback);
public int Native_SetMenuCancelAction(Handle plugin, int numParams)
{
	char sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	Function callback = GetNativeFunction(2);
	
	int group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return false;
	
	// Someone registered a menu back action before. Overwrite it.
	if(group[ZG_menuCancelForward] != INVALID_HANDLE)
		// Private forwards don't allow to just clear all functions from the list. You HAVE to give the plugin handle -.-
		delete group[ZG_menuCancelForward];
	
	// typedef MapZoneMenuCancelCB = function void(int client, int reason, const char[] group);
	group[ZG_menuCancelForward] = CreateForward(ET_Ignore, Param_Cell, Param_Cell, Param_String);
	AddToForward(group[ZG_menuCancelForward], plugin, callback);
	SaveGroup(group);
	
	return true;
}

// native void MapZone_StartAddingZone(int client, const char[] group, const char[] sZoneName = "", bool bEnableCancelForward = false, const char[] sClusterName = "");
public int Native_StartAddingZone(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
		return;
	}
	
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(2, sGroupName, sizeof(sGroupName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid zone group name \"%s\"", sGroupName);
		return;
	}
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(3, sZoneName, sizeof(sZoneName));
	if(ZoneExistsWithName(group, sZoneName))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "There already is a zone named \"%s\" in group \"%s\"", sZoneName, sGroupName);
		return;
	}
	
	if(ClusterExistsWithName(group, sZoneName))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "There already is a cluster named \"%s\" in group \"%s\"", sZoneName, sGroupName);
		return;
	}
	
	bool bEnableCancelForward = view_as<bool>(GetNativeCell(4));
	char sClusterName[MAX_ZONE_NAME];
	GetNativeString(5, sClusterName, sizeof(sClusterName));
	
	// If there is a cluster name provided, add the new zone to that right away.
	if (sClusterName[0])
	{
		int zoneCluster[ZoneCluster];
		if (!GetZoneClusterByName(sClusterName, group, zoneCluster))
		{
			ThrowNativeError(SP_ERROR_NATIVE, "Invalid cluster name \"%s\"", sClusterName);
			return;
		}
		
		g_ClientMenuState[client][CMS_cluster] = zoneCluster[ZC_index];
	}
	
	// Save the zone name if there's one given.
	strcopy(g_ClientMenuState[client][CMS_presetZoneName], MAX_ZONE_NAME, sZoneName);
	g_ClientMenuState[client][CMS_group] = group[ZG_index];
	g_ClientMenuState[client][CMS_backToMenuAfterEdit] = bEnableCancelForward;
	
	// Start the process of adding a new zone.
	StartZoneAdding(client);
}

// native void MapZone_AddCluster(const char[] group, const char[] sClusterName, int iAdmin=0);
public int Native_AddCluster(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sClusterName[MAX_ZONE_NAME];
	GetNativeString(2, sClusterName, sizeof(sClusterName));
	
	int iAdmin = GetNativeCell(3);
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid zone group name \"%s\"", sGroupName);
		return;
	}
	
	// Make sure there is that name isn't taken already.
	if(ZoneExistsWithName(group, sClusterName))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "There already is a zone named \"%s\" in group \"%s\"", sClusterName, sGroupName);
		return;
	}
	
	if(ClusterExistsWithName(group, sClusterName))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "There already is a cluster named \"%s\" in group \"%s\"", sClusterName, sGroupName);
		return;
	}
	
	if (iAdmin < 0 || iAdmin > MaxClients)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid admin client index %d", iAdmin);
		return;
	}
	
	int zoneCluster[ZoneCluster];
	AddNewCluster(group, sClusterName, zoneCluster);
	
	// Inform other plugins that this cluster is now a thing.
	CallOnClusterCreated(group, zoneCluster, iAdmin);
}

// native bool MapZone_ZoneExists(const char[] group, const char[] zoneName);
public int Native_ZoneExists(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	if(ZoneExistsWithName(group, sZoneName))
		return true;
	
	if(ClusterExistsWithName(group, sZoneName))
		return true;
	
	return false;
}

// native int MapZone_GetZoneIndex(const char[] group, const char[] zoneName, MapZoneType &mapZoneType);
public int Native_GetZoneIndex(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid group name \"%s\"", sGroupName);
		return -1;
	}
	
	int zoneData[ZoneData];
	if(GetZoneByName(sZoneName, group, zoneData))
	{
		SetNativeCellRef(3, MapZoneType_Zone);
		return zoneData[ZD_index];
	}
	
	int zoneCluster[ZoneCluster];
	if(GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		SetNativeCellRef(3, MapZoneType_Cluster);
		return zoneCluster[ZC_index];
	}
	
	ThrowNativeError(SP_ERROR_NATIVE, "No zone or cluster with name \"%s\" in group \"%s\".", sZoneName, sGroupName);
	return -1;
}

// native bool MapZone_GetZoneNameByIndex(const char[] group, int zoneIndex, MapZoneType mapZoneType, char[] zoneName, int maxlen);
public int Native_GetZoneNameByIndex(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid group name \"%s\"", sGroupName);
		return false;
	}
	
	int iZoneIndex = GetNativeCell(2);
	MapZoneType iZoneType = view_as<MapZoneType>(GetNativeCell(3));
	int iMaxlen = GetNativeCell(5);
	
	switch (iZoneType)
	{
		case MapZoneType_Zone:
		{
			if (iZoneIndex < 0 || iZoneIndex >= group[ZG_zones].Length)
			{
				ThrowNativeError(SP_ERROR_NATIVE, "Invalid zone index %d", iZoneIndex);
				return false;
			}
			
			int zoneData[ZoneData];
			GetZoneByIndex(iZoneIndex, group, zoneData);
			if (zoneData[ZD_deleted])
				return false;
			
			SetNativeString(4, zoneData[ZD_name], iMaxlen);
		}
		case MapZoneType_Cluster:
		{
			if (iZoneIndex < 0 || iZoneIndex >= group[ZG_cluster].Length)
			{
				ThrowNativeError(SP_ERROR_NATIVE, "Invalid cluster index %d", iZoneIndex);
				return false;
			}
			
			int zoneCluster[ZoneCluster];
			GetZoneClusterByIndex(iZoneIndex, group, zoneCluster);
			if (zoneCluster[ZC_deleted])
				return false;
			
			SetNativeString(4, zoneCluster[ZC_name], iMaxlen);
		}
		default:
		{
			ThrowNativeError(SP_ERROR_NATIVE, "Invalid zone type %d", iZoneType);
			return false;
		}
	}
	
	return true;
}

// native ArrayList MapZone_GetGroupZones(const char[] group, bool bIncludeClusters=true);
public int Native_GetGroupZones(Handle plugin, int numParams)
{
	char sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sName, sizeof(sName));
	
	bool bIncludeClusters = view_as<bool>(GetNativeCell(2));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return view_as<int>(INVALID_HANDLE);
	
	ArrayList hZones = new ArrayList(ByteCountToCells(MAX_ZONE_NAME));
	// Push all regular zone names
	int iSize = group[ZG_zones].Length;
	int zoneData[ZoneData];
	for(int i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		// NOT in a cluster!
		if(zoneData[ZD_clusterIndex] != -1)
			continue;
		
		hZones.PushString(zoneData[ZD_name]);
	}
	
	// Only add clusters, if we're told so.
	if(bIncludeClusters)
	{
		// And all clusters
		int zoneCluster[ZoneCluster];
		iSize = group[ZG_cluster].Length;
		for(int i=0;i<iSize;i++)
		{
			GetZoneClusterByIndex(i, group, zoneCluster);
			if(zoneCluster[ZC_deleted])
				continue;
			
			hZones.PushString(zoneCluster[ZC_name]);
		}
	}
	
	Handle hReturn = CloneHandle(hZones, plugin);
	delete hZones;
	
	return view_as<int>(hReturn);
}

// native MapZoneType MapZone_GetZoneType(const char[] group, const char[] zoneName);
public int Native_GetZoneType(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid group name \"%s\"", sGroupName);
		return 0;
	}
	
	if(ClusterExistsWithName(group, sZoneName))
		return view_as<int>(MapZoneType_Cluster);
	else if(ZoneExistsWithName(group, sZoneName))
		return view_as<int>(MapZoneType_Zone);
	
	ThrowNativeError(SP_ERROR_NATIVE, "No zone or cluster with name \"%s\" in group \"%s\".", sZoneName, sGroupName);
	return 0;
}

// native ArrayList MapZone_GetClusterZones(const char[] group, const char[] clusterName);
public int Native_GetClusterZones(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sClusterName[MAX_ZONE_NAME];
	GetNativeString(2, sClusterName, sizeof(sClusterName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return view_as<int>(INVALID_HANDLE);
	
	int zoneCluster[ZoneCluster];
	if(!GetZoneClusterByName(sClusterName, group, zoneCluster))
		return view_as<int>(INVALID_HANDLE);
	
	ArrayList hZones = new ArrayList(ByteCountToCells(MAX_ZONE_NAME));
	// Push all names of zones in this cluster
	int iSize = group[ZG_zones].Length;
	int zoneData[ZoneData];
	for(int i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		// In this cluster?
		if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
			continue;
		
		hZones.PushArray(view_as<int>(zoneData[ZD_name]), ByteCountToCells(MAX_ZONE_NAME));
	}
	
	Handle hReturn = CloneHandle(hZones, plugin);
	delete hZones;
	
	return view_as<int>(hReturn);
}

// native bool MapZone_GetClusterNameOfZone(const char[] group, const char[] zoneName, char[] clusterName, int maxlen);
public int Native_GetClusterNameOfZone(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid group name \"%s\"", sGroupName);
		return 0;
	}
	
	int zoneData[ZoneData];
	if(!GetZoneByName(sZoneName, group, zoneData))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "No zone \"%s\" in group \"%s\"", sZoneName, sGroupName);
		return 0;
	}
	
	// Not part of a cluster.
	if (zoneData[ZD_clusterIndex] == -1)
		return 0;
	
	int zoneCluster[ZoneCluster];
	GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
	// Better be save than sorry.
	if (zoneCluster[ZC_deleted])
		return 0;
	
	// Return the cluster name.
	int iMaxlen = GetNativeCell(4);
	SetNativeString(3, zoneCluster[ZC_name], iMaxlen);
	return 1;
}

// native bool MapZone_SetZoneName(const char[] group, const char[] sOldName, const char[] sNewName);
public int Native_SetZoneName(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sCurrentName[MAX_ZONE_NAME];
	GetNativeString(2, sCurrentName, sizeof(sCurrentName));
	
	char sNewName[MAX_ZONE_NAME];
	GetNativeString(3, sNewName, sizeof(sNewName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid group name \"%s\"", sGroupName);
		return false;
	}
	
	// Get the data structure of the zone by the old name.
	MapZoneType iZoneType;
	int zoneData[ZoneData], zoneCluster[ZoneCluster];
	if (GetZoneByName(sCurrentName, group, zoneData))
	{
		iZoneType = MapZoneType_Zone;
	}
	else if (GetZoneClusterByName(sCurrentName, group, zoneCluster))
	{
		iZoneType = MapZoneType_Cluster;
	}
	else
	{
		ThrowNativeError(SP_ERROR_NATIVE, "No zone or cluster with name \"%s\" in group \"%s\".", sCurrentName, sGroupName);
		return false;
	}
	
	// Make sure there is no other zone named by the new name.
	if(ZoneExistsWithName(group, sNewName) || ClusterExistsWithName(group, sNewName))
		return false;
	
	if (iZoneType == MapZoneType_Zone)
	{
		strcopy(zoneData[ZD_name], MAX_ZONE_NAME, sNewName);
		SaveZone(group, zoneData);
	}
	else
	{
		strcopy(zoneCluster[ZC_name], MAX_ZONE_NAME, sNewName);
		SaveCluster(group, zoneCluster);
	}
	
	return true;
}

// native void MapZone_GetZonePosition(const char[] group, const char[] sZoneName, float fCenter[3]);
public int Native_GetZonePosition(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid group name \"%s\"", sGroupName);
		return;
	}
	
	// Get the center position of the zone or cluster.
	float fCenter[3];
	int zoneData[ZoneData];
	if (GetZoneByName(sZoneName, group, zoneData))
	{
		Array_Copy(zoneData[ZD_position], fCenter, sizeof(fCenter));
	}
	/*else if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		// TODO: Pick a zone in the cluster?
	}*/
	else
	{
		ThrowNativeError(SP_ERROR_NATIVE, "No zone with name \"%s\" in group \"%s\".", sZoneName, sGroupName);
		return;
	}
	
	SetNativeArray(3, fCenter, 3);
}

// native bool MapZone_GetCustomString(const char[] group, const char[] zoneName, const char[] key, char[] value, int maxlen);
public int Native_GetCustomString(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	// Find a matching cluster or zone.
	int zoneCluster[ZoneCluster], zoneData[ZoneData];
	StringMap hCustomKV;
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
	
	char sKey[128];
	GetNativeString(3, sKey, sizeof(sKey));
	int maxlen = GetNativeCell(5);
	
	char[] sValue = new char[maxlen];
	if (!hCustomKV.GetString(sKey, sValue, maxlen))
		return false;
	
	SetNativeString(4, sValue, maxlen);
	
	return true;
}

// native bool MapZone_SetCustomString(const char[] group, const char[] zoneName, const char[] key, const char[] value);
public int Native_SetCustomString(Handle plugin, int numParams)
{
	char sGroupName[MAX_ZONE_GROUP_NAME];
	GetNativeString(1, sGroupName, sizeof(sGroupName));
	
	int group[ZoneGroup];
	if(!GetGroupByName(sGroupName, group))
		return false;
	
	char sZoneName[MAX_ZONE_NAME];
	GetNativeString(2, sZoneName, sizeof(sZoneName));
	
	// Find a matching cluster or zone.
	int zoneCluster[ZoneCluster], zoneData[ZoneData];
	StringMap hCustomKV;
	if (GetZoneClusterByName(sZoneName, group, zoneCluster))
	{
		if (!zoneCluster[ZC_customKV])
			zoneCluster[ZC_customKV] = new StringMap();
		
		hCustomKV = zoneCluster[ZC_customKV];
		zoneCluster[ZC_customKVChanged] = true;
		SaveCluster(group, zoneCluster);
	}
	else if (GetZoneByName(sZoneName, group, zoneData))
	{
		if (!zoneData[ZD_customKV])
			zoneData[ZD_customKV] = new StringMap();
		
		hCustomKV = zoneData[ZD_customKV];
		zoneData[ZD_customKVChanged] = true;
		SaveZone(group, zoneData);
	}
	
	// No zone/cluster with this name
	if (!hCustomKV)
		return false;
	
	char sKey[128], sValue[256];
	GetNativeString(3, sKey, sizeof(sKey));
	GetNativeString(4, sValue, sizeof(sValue));
	
	// Don't save empty values. Just remove the key then.
	if (sValue[0] == '\0')
		return hCustomKV.Remove(sKey);

	return hCustomKV.SetString(sKey, sValue);
}

/**
 * Entity output handler
 */
public void EntOut_OnTouchEvent(const char[] output, int caller, int activator, float delay)
{
	// Ignore invalid touches
	if(activator < 1 || activator > MaxClients)
		return;

	// Get the targetname
	char sTargetName[64];
	GetEntPropString(caller, Prop_Data, "m_iName", sTargetName, sizeof(sTargetName));
	
	int iGroupIndex, iZoneIndex;
	if(!ExtractIndicesFromString(sTargetName, iGroupIndex, iZoneIndex))
		return;
	
	// This zone shouldn't exist!
	if(iGroupIndex >= g_hZoneGroups.Length)
	{
		AcceptEntityInput(caller, "Kill");
		return;
	}
	
	int group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(iGroupIndex, group);
	
	if(iZoneIndex >= group[ZG_zones].Length)
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
	
	bool bEnteredZone = StrEqual(output, "OnStartTouch") || StrEqual(output, "OnTrigger");
	
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
	char sZoneName[MAX_ZONE_NAME];
	strcopy(sZoneName, sizeof(sZoneName), zoneData[ZD_name]);
	if(zoneData[ZD_clusterIndex] != -1)
	{
		int zoneCluster[ZoneCluster];
		GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
		
		bool bFireForward;
		
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
public Action Timer_ShowZones(Handle timer)
{
	float fDistanceLimit = g_hCVDebugBeamDistance.FloatValue;

	int iNumGroups = g_hZoneGroups.Length;
	int group[ZoneGroup], zoneCluster[ZoneCluster], zoneData[ZoneData], iNumZones;
	float fPos[3], fMins[3], fMaxs[3], fAngles[3];
	int[] iClients = new int[MaxClients];
	int iNumClients;
	int iDefaultColor[4], iColor[4];
	
	bool bOptimizeBeams = g_hCVOptimizeBeams.BoolValue;
	
	float vFirstPoint[3], vSecondPoint[3];
	float fClientAngles[3], fClientEyePosition[3], fClientToZonePoint[3], fLength;
	for(int i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		
		Array_Copy(group[ZG_defaultColor], iDefaultColor, 4);
		iNumZones = group[ZG_zones].Length;
		for(int z=0;z<iNumZones;z++)
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
			for(int c=1;c<=MaxClients;c++)
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
				Effect_DrawBeamBoxRotatable(iClients, iNumClients, fPos, fMins, fMaxs, fAngles, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 2.0, 2.0, 2, 1.0, iColor, 5);
		}
	}
	
	
	for(int i=1;i<=MaxClients;i++)
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
			Effect_DrawBeamBoxRotatableToClient(i, fPos, fMins, fMaxs, fAngles, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 2.0, 2.0, 2, 1.0, {0,0,255,255}, 0);
			Effect_DrawAxisOfRotationToClient(i, fPos, fAngles, view_as<float>({20.0,20.0,20.0}), g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 2.0, 2.0, 2, 1.0, 0);
		}
	}
	
	return Plugin_Continue;
}

public Action Timer_ShowZoneWhileAdding(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (!client)
		return Plugin_Stop;
	
	// Don't show temporary stuff anymore when done with both corners.
	if(g_ClientMenuState[client][CMS_editState] == ZES_name)
	{
		// Keep drawing the new zone while he enters a name for it.
		if (g_ClientMenuState[client][CMS_addZone])
		{
			float fFirstPoint[3], fSecondPoint[3];
			Array_Copy(g_ClientMenuState[client][CMS_first], fFirstPoint, 3);
			Array_Copy(g_ClientMenuState[client][CMS_second], fSecondPoint, 3);
			
			Effect_DrawBeamBoxToClient(client, fFirstPoint, fSecondPoint, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 2.0, 2.0, 2, 1.0, {0,0,255,255}, 0);
		}
		return Plugin_Continue;
	}
	
	// Don't show anything when preview is disabled.
	if(g_ClientMenuState[client][CMS_disablePreview])
		return Plugin_Continue;
	
	// Get the client's aim position.
	float fAimPosition[3], fUnsnappedAimPosition[3];
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
	float fTargetPosition[3], fUnsnappedTargetPosition[3];
	if (g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
	{
		fTargetPosition = fAimPosition;
		fUnsnappedTargetPosition = fUnsnappedAimPosition;
	}
	else
	{
		float fGroundNormal[3];
		GetClientFeetPosition(client, fUnsnappedTargetPosition, fGroundNormal);
		SnapToGrid(client, fUnsnappedTargetPosition, fTargetPosition, fGroundNormal);
		
		TE_SetupGlowSprite(fTargetPosition, g_iGlowSprite, 0.1, 0.7, 150);
		TE_SendToClient(client);
		
		// Put the start position a little bit higher and behind the player.
		// That way you still see the beam, even if it's right below you.
		fUnsnappedTargetPosition[2] += 32.0;
		float fViewDirection[3];
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
			int group[ZoneGroup], zoneData[ZoneData];
			GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
			
			// Only change the center of the box, keep all the other paramters the same.
			float fCenter[3], fRotation[3], fMins[3], fMaxs[3];
			fCenter = fTargetPosition;
			Array_Copy(zoneData[ZD_rotation], fRotation, 3);
			Array_Copy(zoneData[ZD_mins], fMins, 3);
			Array_Copy(zoneData[ZD_maxs], fMaxs, 3);
			
			Effect_DrawBeamBoxRotatableToClient(client, fCenter, fMins, fMaxs, fRotation, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 2.0, 2.0, 2, 1.0, {0,0,255,255}, 0);
			return Plugin_Continue;
		}
		
		float fFirstPoint[3], fSecondPoint[3];
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
		Effect_DrawBeamBoxToClient(client, fFirstPoint, fSecondPoint, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 2.0, 2.0, 2, 1.0, {0,0,255,255}, 0);
	}
	
	return Plugin_Continue;
}

void ShowGridSnapBeamToClient(int client, float fFirstPoint[3], float fSecondPoint[3])
{
	TE_SetupBeamPoints(fFirstPoint, fSecondPoint, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 1.0, 1.0, 2, 1.0, {0,255,0,255}, 0);
	TE_SendToClient(client);
}

/**
 * Menu stuff
 */
void DisplayGroupRootMenu(int client, int group[ZoneGroup])
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

	Menu hMenu = new Menu(Menu_HandleGroupRoot);
	hMenu.SetTitle("Manage zone group \"%s\"", group[ZG_name]);
	hMenu.ExitButton = true;
	if(group[ZG_menuCancelForward] != INVALID_HANDLE)
		hMenu.ExitBackButton = true;
	
	char sBuffer[64];
	hMenu.AddItem("add", "Add new zone");
	hMenu.AddItem("paste", "Paste zone from clipboard", (HasZoneInClipboard(client)?ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED));
	Format(sBuffer, sizeof(sBuffer), "Show Zones to all: %T", (group[ZG_showZones]?"Yes":"No"), client);
	hMenu.AddItem("showzonesall", sBuffer);
	Format(sBuffer, sizeof(sBuffer), "Show Zones to me only: %T\n \n", (group[ZG_adminShowZones][client]?"Yes":"No"), client);
	hMenu.AddItem("showzonesme", sBuffer);
	
	// Show zone count
	int iNumZones, zoneData[ZoneData];
	int iSize = group[ZG_zones].Length;
	for(int i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		if(zoneData[ZD_clusterIndex] != -1)
			continue;
		iNumZones++;
	}
	Format(sBuffer, sizeof(sBuffer), "List standalone zones (%d)", iNumZones);
	hMenu.AddItem("zones", sBuffer);
	
	// Show cluster count
	int iNumClusters, zoneCluster[ZoneCluster];
	iSize = group[ZG_cluster].Length;
	for(int i=0;i<iSize;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		if(zoneCluster[ZC_deleted])
			continue;
		iNumClusters++;
	}
	Format(sBuffer, sizeof(sBuffer), "List zone clusters (%d)", iNumClusters);
	hMenu.AddItem("clusters", sBuffer);
	
	g_ClientMenuState[client][CMS_group] = group[ZG_index];
	hMenu.Display(client, MENU_TIME_FOREVER);
	
	// We might have interrupted one of our own menus which cancelled and unset our group state :(
	g_ClientMenuState[client][CMS_group] = group[ZG_index];
}

public int Menu_HandleGroupRoot(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		// Handle toggling of zone visibility first
		if(StrEqual(sInfo, "showzonesall"))
		{
			// warning 226: a variable is assigned to itself (symbol "group")
			//group[ZG_showZones] = !group[ZG_showZones];
			bool swap = group[ZG_showZones];
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
			bool swap = !group[ZG_adminShowZones][param1];
			group[ZG_adminShowZones][param1] = swap;
			SaveGroup(group);
			
			// Set the zones in this group to show for this admin or not.
			int iNumZones = group[ZG_zones].Length;
			int zoneData[ZoneData];
			for(int i=0;i<iNumZones;i++)
			{
				GetZoneByIndex(i, group, zoneData);
				zoneData[ZD_adminShowZone][param1] = swap;
				SaveZone(group, zoneData);
			}
			
			// Remember this setting for contained clusters too.
			int iNumClusters = group[ZG_cluster].Length;
			int zoneCluster[ZoneCluster];
			for(int i=0;i<iNumClusters;i++)
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
			StartZoneAdding(param1);
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
		int group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		// This group has a menu back action handler registered? Call it!
		if(group[ZG_menuCancelForward] != INVALID_HANDLE)
		{
			Call_StartForward(group[ZG_menuCancelForward]);
			Call_PushCell(param1);
			Call_PushCell(param2);
			Call_PushString(group[ZG_name]);
			Call_Finish();
		}
		g_ClientMenuState[param1][CMS_group] = -1;
	}
}

void DisplayZoneListMenu(int client)
{
	int group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		
	Menu hMenu = new Menu(Menu_HandleZoneList);
	if(g_ClientMenuState[client][CMS_cluster] == -1)
	{
		hMenu.SetTitle("Manage zones for \"%s\"", group[ZG_name]);
	}
	else
	{
		// Reuse this menu to add zones to a cluster form the cluster edit menu directly.
		// It looks the same, is just handled differently.
		int zoneCluster[ZoneCluster];
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
		hMenu.SetTitle("Add zones to cluster \"%s\"", zoneCluster[ZC_name]);
	}
	hMenu.ExitBackButton = true;

	hMenu.AddItem("add", "Add new zone\n \n");

	char sBuffer[64];
	int iNumZones = group[ZG_zones].Length;
	int zoneData[ZoneData], iZoneCount;
	for(int i=0;i<iNumZones;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		// Ignore zones marked as deleted.
		if(zoneData[ZD_deleted])
			continue;
		
		// Only display zones NOT in a cluster.
		if(zoneData[ZD_clusterIndex] != -1)
			continue;
		
		IntToString(i, sBuffer, sizeof(sBuffer));
		hMenu.AddItem(sBuffer, zoneData[ZD_name]);
		iZoneCount++;
	}
	
	if(!iZoneCount)
	{
		hMenu.AddItem("", "No zones in this group.", ITEMDRAW_DISABLED);
	}
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleZoneList(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		if(StrEqual(sInfo, "add"))
		{
			StartZoneAdding(param1);
			return;
		}
		
		int iZoneIndex = StringToInt(sInfo);

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
			int group[ZoneGroup], zoneCluster[ZoneCluster], zoneData[ZoneData];
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

			// Check if the zone was in a cluster before
			if (zoneData[ZD_clusterIndex] != -1)
			{
				int oldZoneCluster[ZoneCluster];
				GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, oldZoneCluster);
				if (!oldZoneCluster[ZC_deleted])
				{
					// Inform other plugins that this zone is no longer part of that cluster.
					CallOnRemovedFromCluster(group, zoneData, oldZoneCluster, param1);
					
					// TODO: Evaluate again, if the client is still in the old cluster?
				}
			}
			
			// Add the zone to the cluster and display the list right again.
			zoneData[ZD_clusterIndex] = g_ClientMenuState[param1][CMS_cluster];
			SaveZone(group, zoneData);
			PrintToChat(param1, "Map Zones > Added zone \"%s\" to cluster \"%s\" in group \"%s\".", zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
			
			// Inform other plugins about this change.
			CallOnAddedToCluster(group, zoneData, zoneCluster, param1);
			
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
				int group[ZoneGroup];
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

void DisplayClusterListMenu(int client)
{
	int group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	
	Menu hMenu = new Menu(Menu_HandleClusterList);
	hMenu.SetTitle("Manage clusters for \"%s\"\nZones in a cluster will act like one big zone.\nAllows for different shapes than just rectangles.", group[ZG_name]);
	hMenu.ExitBackButton = true;

	hMenu.AddItem("add", "Add cluster\n \n");
	
	char sBuffer[64];
	int iNumClusters = group[ZG_cluster].Length;
	int zoneCluster[ZoneCluster], iClusterCount;
	for(int i=0;i<iNumClusters;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		// Ignore clusters marked as deleted.
		if(zoneCluster[ZC_deleted])
			continue;
		
		IntToString(i, sBuffer, sizeof(sBuffer));
		hMenu.AddItem(sBuffer, zoneCluster[ZC_name]);
		iClusterCount++;
	}
	
	if(!iClusterCount)
	{
		hMenu.AddItem("", "No clusters in this group.", ITEMDRAW_DISABLED);
	}
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleClusterList(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		if(StrEqual(sInfo, "add"))
		{
			PrintToChat(param1, "Map Zones > Enter name of new cluster in chat. Type \"!abort\" to abort.");
			g_ClientMenuState[param1][CMS_addCluster] = true;
			return;
		}
		
		int iClusterIndex = StringToInt(sInfo);
		g_ClientMenuState[param1][CMS_cluster] = iClusterIndex;
		DisplayClusterEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			int group[ZoneGroup];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			DisplayGroupRootMenu(param1, group);
		}
		else
		{
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

void DisplayClusterEditMenu(int client)
{
	int group[ZoneGroup], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);

	if(zoneCluster[ZC_deleted])
	{
		g_ClientMenuState[client][CMS_cluster] = -1;
		// Don't open our own menus when we're told to call the menu cancel forward.
		if (TryCallMenuCancelForward(client, MenuCancel_ExitBack))
		{
			g_ClientMenuState[client][CMS_group] = -1;
			return;
		}
		
		DisplayClusterListMenu(client);
		return;
	}
	
	Menu hMenu = new Menu(Menu_HandleClusterEdit);
	hMenu.ExitBackButton = true;
	hMenu.SetTitle("Manage cluster \"%s\" of group \"%s\"", zoneCluster[ZC_name], group[ZG_name]);
	
	char sBuffer[64];
	Format(sBuffer, sizeof(sBuffer), "Show zones in this cluster to me: %T", (zoneCluster[ZC_adminShowZones][client]?"Yes":"No"), client);
	hMenu.AddItem("show", sBuffer);
	hMenu.AddItem("add", "Add zone to cluster");
	
	char sTeam[32] = "Any";
	if(zoneCluster[ZC_teamFilter] > 1)
		GetTeamName(zoneCluster[ZC_teamFilter], sTeam, sizeof(sTeam));
	Format(sBuffer, sizeof(sBuffer), "Team filter: %s", sTeam);
	hMenu.AddItem("team", sBuffer);
	hMenu.AddItem("paste", "Paste zone from clipboard", (HasZoneInClipboard(client)?ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED));
	hMenu.AddItem("rename", "Rename");
	hMenu.AddItem("delete", "Delete");
	
	hMenu.AddItem("", "Zones:", ITEMDRAW_DISABLED);
	int iNumZones = group[ZG_zones].Length;
	int zoneData[ZoneData], iZoneCount;
	for(int i=0;i<iNumZones;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		// Ignore zones marked as deleted.
		if(zoneData[ZD_deleted])
			continue;
		
		// Only display zones NOT in a cluster.
		if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
			continue;
		
		IntToString(i, sBuffer, sizeof(sBuffer));
		hMenu.AddItem(sBuffer, zoneData[ZD_name]);
		iZoneCount++;
	}
	
	if(!iZoneCount)
	{
		hMenu.AddItem("", "No zones in this cluster.", ITEMDRAW_DISABLED);
	}
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleClusterEdit(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup], zoneCluster[ZoneCluster];
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
			bool swap = !zoneCluster[ZC_adminShowZones][param1];
			zoneCluster[ZC_adminShowZones][param1] = swap;
			SaveCluster(group, zoneCluster);
			
			// Set all zones of this cluster to the same state.
			int iNumZones = group[ZG_zones].Length;
			int zoneData[ZoneData];
			for(int i=0;i<iNumZones;i++)
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
			int iTeam = zoneCluster[ZC_teamFilter];
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
			int iNumZones = group[ZG_zones].Length;
			int zoneData[ZoneData];
			for(int i=0;i<iNumZones;i++)
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
			char sBuffer[128];
			Panel hPanel = new Panel();
			Format(sBuffer, sizeof(sBuffer), "Do you really want to delete cluster \"%s\"?", zoneCluster[ZC_name]);
			hPanel.SetTitle(sBuffer);
			
			hPanel.DrawItem("Yes, delete cluster and all contained zones");
			hPanel.DrawItem("Yes, delete cluster, but keep all contained zones");
			hPanel.DrawItem("No, DON'T delete anything");
			
			hPanel.Send(param1, Panel_HandleConfirmDeleteCluster, MENU_TIME_FOREVER);
			delete hPanel;
		}
		else
		{
			int iZoneIndex = StringToInt(sInfo);
			g_ClientMenuState[param1][CMS_zone] = iZoneIndex;
			DisplayZoneEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_cluster] = -1;
		
		// Don't open our own menus when we're told to call the menu cancel forward.
		if (TryCallMenuCancelForward(param1, param2))
		{
			g_ClientMenuState[param1][CMS_group] = -1;
			return;
		}
		
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

public int Panel_HandleConfirmDeleteCluster(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		// Selected "No", go back.
		if(param2 > 2)
		{
			DisplayClusterEditMenu(param1);
			return;
		}
		
		int group[ZoneGroup], zoneCluster[ZoneCluster];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneClusterByIndex(g_ClientMenuState[param1][CMS_cluster], group, zoneCluster);
		
		bool bDeleteZones = param2 == 1;
		
		// Delete all contained zones in the cluster too.
		// Make sure the trigger is removed.
		int iNumZones = group[ZG_zones].Length;
		int zoneData[ZoneData];
		int iZonesCount;
		for(int i=0;i<iNumZones;i++)
		{
			GetZoneByIndex(i, group, zoneData);
			if(zoneData[ZD_deleted])
				continue;
			
			// Only delete zones in this cluster!
			if(zoneData[ZD_clusterIndex] != zoneCluster[ZC_index])
				continue;
			
			// Want to delete the zones in the cluster too?
			if(bDeleteZones)
			{
				RemoveZoneTrigger(group, zoneData);
				zoneData[ZD_deleted] = true;
				
				// Call this before actually deleting, so other plugins can still access the properties.
				CallOnZoneRemoved(group, zoneData, param1);
			}
			// Just remove the zone from the cluster, but keep it.
			else
			{
				zoneData[ZD_clusterIndex] = -1;
			}
			SaveZone(group, zoneData);
			
			// Inform other plugins that this zone is now "created" on it's own.
			if (!bDeleteZones)
				CallOnRemovedFromCluster(group, zoneData, zoneCluster, param1);
			
			iZonesCount++;
		}
		
		// Inform other plugins that this cluster is now history.
		CallOnClusterRemoved(group, zoneCluster, param1);
		
		// We can't really delete it, because the array indicies would shift. Just don't save it to file and skip it.
		zoneCluster[ZC_deleted] = true;
		SaveCluster(group, zoneCluster);
		
		g_ClientMenuState[param1][CMS_cluster] = -1;
		// Don't open our own menu if we're told to call the menu cancel callback.
		if (TryCallMenuCancelForward(param1, MenuCancel_ExitBack))
		{
			g_ClientMenuState[param1][CMS_group] = -1;
			return;
		}
		
		DisplayClusterListMenu(param1);
		
		if(bDeleteZones)
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

void DisplayZoneEditMenu(int client)
{
	int group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);

	if(zoneData[ZD_deleted])
	{
		if (TryCallMenuCancelForward(client, MenuCancel_ExitBack))
		{
			g_ClientMenuState[client][CMS_group] = -1;
			g_ClientMenuState[client][CMS_zone] = -1;
			g_ClientMenuState[client][CMS_cluster] = -1;
			return;
		}
		DisplayGroupRootMenu(client, group);
		return;
	}
	
	Menu hMenu = new Menu(Menu_HandleZoneEdit);
	hMenu.ExitBackButton = true;
	if(zoneData[ZD_clusterIndex] == -1)
		hMenu.SetTitle("Manage zone \"%s\" in group \"%s\"", zoneData[ZD_name], group[ZG_name]);
	else
	{
		GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
		hMenu.SetTitle("Manage zone \"%s\" in cluster \"%s\" of group \"%s\"", zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
	}
	
	char sBuffer[128];
	hMenu.AddItem("teleport", "Teleport to");
	Format(sBuffer, sizeof(sBuffer), "Show zone to me: %T", (zoneData[ZD_adminShowZone][client]?"Yes":"No"), client);
	hMenu.AddItem("show", sBuffer);
	hMenu.AddItem("edit", "Edit zone");
	
	char sTeam[32] = "Any";
	if(zoneData[ZD_teamFilter] > 1)
		GetTeamName(zoneData[ZD_teamFilter], sTeam, sizeof(sTeam));
	Format(sBuffer, sizeof(sBuffer), "Team filter: %s", sTeam);
	hMenu.AddItem("team", sBuffer);
	
	if(zoneData[ZD_clusterIndex] == -1)
		Format(sBuffer, sizeof(sBuffer), "Add to a cluster");
	else
		Format(sBuffer, sizeof(sBuffer), "Remove from cluster \"%s\"", zoneCluster[ZC_name]);
	hMenu.AddItem("cluster", sBuffer);
	hMenu.AddItem("copy", "Copy to clipboard");
	hMenu.AddItem("rename", "Rename");
	hMenu.AddItem("delete", "Delete");
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleZoneEdit(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup], zoneData[ZoneData];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		// Teleport to the zone
		if(StrEqual(sInfo, "teleport"))
		{
			float vBuf[3];
			Array_Copy(zoneData[ZD_position], vBuf, 3);
			TeleportEntity(param1, vBuf, NULL_VECTOR, NULL_VECTOR);
			DisplayZoneEditMenu(param1);
		}
		// Show zone to admin
		else if(StrEqual(sInfo, "show"))
		{
			bool swap = !zoneData[ZD_adminShowZone][param1];
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
			int iTeam = zoneData[ZD_teamFilter];
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
				int zoneCluster[ZoneCluster];
				GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
			
				char sBuffer[128];
				Panel hPanel = new Panel();
				Format(sBuffer, sizeof(sBuffer), "Do you really want to remove zone \"%s\" from cluster \"%s\"?", zoneData[ZD_name], zoneCluster[ZC_name]);
				hPanel.SetTitle(sBuffer);
				
				Format(sBuffer, sizeof(sBuffer), "%T", "Yes", param1);
				hPanel.DrawItem(sBuffer);
				Format(sBuffer, sizeof(sBuffer), "%T", "No", param1);
				hPanel.DrawItem(sBuffer);
				
				hPanel.Send(param1, Panel_HandleConfirmRemoveFromCluster, MENU_TIME_FOREVER);
				delete hPanel;
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
			char sBuffer[128];
			Panel hPanel = new Panel();
			Format(sBuffer, sizeof(sBuffer), "Do you really want to delete zone \"%s\"?", zoneData[ZD_name]);
			hPanel.SetTitle(sBuffer);
			
			Format(sBuffer, sizeof(sBuffer), "%T", "Yes", param1);
			hPanel.DrawItem(sBuffer);
			Format(sBuffer, sizeof(sBuffer), "%T", "No", param1);
			hPanel.DrawItem(sBuffer);
			
			hPanel.Send(param1, Panel_HandleConfirmDeleteZone, MENU_TIME_FOREVER);
			delete hPanel;
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_zone] = -1;
		
		// If this zone is in a cluster, always go back to the cluster edit menu.
		if(param2 == MenuCancel_ExitBack
		&& g_ClientMenuState[param1][CMS_cluster] != -1)
		{
			DisplayClusterEditMenu(param1);
			return;
		}
		
		// Don't open our own menus when we're told to call the menu cancel forward.
		if (TryCallMenuCancelForward(param1, param2))
		{
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			return;
		}
		
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayZoneListMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
		}
	}
}

void DisplayZoneEditDetailsMenu(int client)
{
	int group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);

	if(zoneData[ZD_deleted])
	{
		if (TryCallMenuCancelForward(client, MenuCancel_ExitBack))
		{
			g_ClientMenuState[client][CMS_group] = -1;
			g_ClientMenuState[client][CMS_zone] = -1;
			g_ClientMenuState[client][CMS_cluster] = -1;
			return;
		}
		
		DisplayGroupRootMenu(client, group);
		return;
	}
	
	Menu hMenu = new Menu(Menu_HandleZoneEditDetails);
	hMenu.ExitBackButton = true;
	if(g_ClientMenuState[client][CMS_cluster] == -1)
		hMenu.SetTitle("Edit zone \"%s\" in group \"%s\"", zoneData[ZD_name], group[ZG_name]);
	else
	{
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
		hMenu.SetTitle("Edit zone \"%s\" in cluster \"%s\" of group \"%s\"", zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
	}
	
	hMenu.AddItem("position1", "Change first corner");
	hMenu.AddItem("position2", "Change second corner");
	hMenu.AddItem("center", "Move center of zone");
	hMenu.AddItem("rotation", "Change rotation");
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleZoneEditDetails(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup], zoneData[ZoneData];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		// Change one of the 2 positions of the zone
		if(!StrContains(sInfo, "position"))
		{
			g_ClientMenuState[param1][CMS_editState] = (StrEqual(sInfo, "position1")?ZES_first:ZES_second);
			g_ClientMenuState[param1][CMS_editPosition] = true;
			
			// Get the current zone bounds as base to edit from.
			for(int i=0;i<3;i++)
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
			TryCallMenuCancelForward(param1, param2);
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
		}
	}
}

void DisplayClusterSelectionMenu(int client)
{
	int group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	
	Menu hMenu = new Menu(Menu_HandleClusterSelection);
	hMenu.SetTitle("Add zone \"%s\" to cluster:", zoneData[ZD_name]);
	hMenu.ExitBackButton = true;

	hMenu.AddItem("newcluster", "Add new cluster\n \n");
	
	int iNumClusters = group[ZG_cluster].Length;
	int zoneCluster[ZoneCluster], iClusterCount;
	char sIndex[16];
	for(int i=0;i<iNumClusters;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		
		if(zoneCluster[ZC_deleted])
			continue;
		
		IntToString(i, sIndex, sizeof(sIndex));
		hMenu.AddItem(sIndex, zoneCluster[ZC_name]);
		iClusterCount++;
	}
	
	if(!iClusterCount)
		hMenu.AddItem("", "No clusters available.", ITEMDRAW_DISABLED);
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleClusterSelection(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		if (StrEqual(sInfo, "newcluster"))
		{
			PrintToChat(param1, "Map Zones > Enter name of new cluster in chat. Type \"!abort\" to abort.");
			g_ClientMenuState[param1][CMS_addCluster] = true;
			return;
		}
		
		int group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
		
		int iClusterIndex = StringToInt(sInfo);
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
		
		CallOnAddedToCluster(group, zoneData, zoneCluster, param1);
		
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
			TryCallMenuCancelForward(param1, param2);
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

public int Panel_HandleConfirmRemoveFromCluster(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		// Selected "Yes" -> remove zone from cluster.
		if(param2 == 1)
		{
			int group[ZoneGroup], zoneData[ZoneData], zoneCluster[ZoneCluster];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
			if(zoneData[ZD_clusterIndex] != -1)
				GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
			
			zoneData[ZD_clusterIndex] = -1;
			SaveZone(group, zoneData);
			
			// Inform other plugins that this zone is now on its own.
			CallOnRemovedFromCluster(group, zoneData, zoneCluster, param1);
			
			LogAction(param1, -1, "%L removed zone \"%s\" from cluster \"%s\" in group \"%s\".", param1, zoneData[ZD_name], zoneCluster[ZC_name], group[ZG_name]);
		}
		
		DisplayZoneEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		TryCallMenuCancelForward(param1, param2);
		g_ClientMenuState[param1][CMS_group] = -1;
		g_ClientMenuState[param1][CMS_cluster] = -1;
		g_ClientMenuState[param1][CMS_zone] = -1;
	}
}

public int Panel_HandleConfirmDeleteZone(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		// Selected "Yes" -> delete the zone.
		if(param2 == 1)
		{
			int group[ZoneGroup], zoneData[ZoneData];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[param1][CMS_zone], group, zoneData);
			
			// Inform other plugins that this zone is no more.
			// Do it before marking it as deleted, so the plugins can still access its properties.
			CallOnZoneRemoved(group, zoneData, param1);
			
			// We can't really delete it, because the array indicies would shift. Just don't save it to file and skip it.
			zoneData[ZD_deleted] = true;
			SaveZone(group, zoneData);
			RemoveZoneTrigger(group, zoneData);
			g_ClientMenuState[param1][CMS_zone] = -1;
			
			if(g_ClientMenuState[param1][CMS_cluster] == -1)
			{
				LogAction(param1, -1, "%L deleted zone \"%s\" of group \"%s\".", param1, zoneData[ZD_name], group[ZG_name]);
				// Don't open our own menu if we're told to call the menu cancel callback.
				if (TryCallMenuCancelForward(param1, MenuCancel_ExitBack))
				{
					g_ClientMenuState[param1][CMS_group] = -1;
					return;
				}
				
				DisplayZoneListMenu(param1);
			}
			else
			{
				int zoneCluster[ZoneCluster];
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
		TryCallMenuCancelForward(param1, param2);
		g_ClientMenuState[param1][CMS_group] = -1;
		g_ClientMenuState[param1][CMS_cluster] = -1;
		g_ClientMenuState[param1][CMS_zone] = -1;
	}
}

// Edit one of the points or the center of the zone.
void DisplayZonePointEditMenu(int client)
{
	// Start the display timer, if this is the first time we open this menu.
	if (!g_hShowZoneWhileEditTimer[client])
		g_hShowZoneWhileEditTimer[client] = CreateTimer(0.1, Timer_ShowZoneWhileAdding, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);

	int group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	
	Menu hMenu = new Menu(Menu_HandleZonePointEdit);
	if(g_ClientMenuState[client][CMS_addZone])
	{
		hMenu.SetTitle("Add new zone > Position %d\nClick on the point or push \"e\" to set it at your feet.", view_as<int>(g_ClientMenuState[client][CMS_editState])+1);
	}
	else
	{
		int zoneData[ZoneData];
		GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
		if(g_ClientMenuState[client][CMS_editCenter])
		{
			hMenu.SetTitle("Edit zone \"%s\" center\nClick on the point or push \"e\" to set it at your feet.", zoneData[ZD_name]);
		}
		else
		{
			hMenu.SetTitle("Edit zone \"%s\" position %d\nClick on the point or push \"e\" to set it at your feet.", zoneData[ZD_name], view_as<int>(g_ClientMenuState[client][CMS_editState])+1);
		}
	}
	hMenu.ExitBackButton = true;

	if(!g_ClientMenuState[client][CMS_addZone])
		hMenu.AddItem("save", "Save changes");
	
	char sBuffer[256] = "Show preview: ";
	switch (g_ClientMenuState[client][CMS_previewMode])
	{
		case ZPM_aim:
			StrCat(sBuffer, sizeof(sBuffer), "Aim");
		case ZPM_feet:
			StrCat(sBuffer, sizeof(sBuffer), "At your feet");
	}
	hMenu.AddItem("togglepreview", sBuffer);
	
	Format(sBuffer, sizeof(sBuffer), "Stepsize: %.0f", g_fStepsizes[g_ClientMenuState[client][CMS_stepSizeIndex]]);
	hMenu.AddItem("togglestepsize", sBuffer);
	
	if (g_ClientMenuState[client][CMS_aimCapDistance] < 0.0)
	{
		Format(sBuffer, sizeof(sBuffer), "Max. aim distance: Disabled");
		if (g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
			Format(sBuffer, sizeof(sBuffer), "%s\nHold rightclick and move mouse up and down to change.", sBuffer);
		hMenu.AddItem("resetaimdistance", sBuffer, ITEMDRAW_DISABLED);
	}
	else
	{
		Format(sBuffer, sizeof(sBuffer), "Max. aim distance: %.2f", g_ClientMenuState[client][CMS_aimCapDistance]);
		if (g_ClientMenuState[client][CMS_previewMode] == ZPM_aim)
			Format(sBuffer, sizeof(sBuffer), "%s\nHold rightclick and move mouse up and down to change.", sBuffer);
		Format(sBuffer, sizeof(sBuffer), "%s\nSelect menu option to remove limit.", sBuffer);
		hMenu.AddItem("resetaimdistance", sBuffer);
	}
	
	Format(sBuffer, sizeof(sBuffer), "Snap to map grid: %s", g_ClientMenuState[client][CMS_snapToGrid]?"Enabled":"Disabled");
	hMenu.AddItem("togglegridsnap", sBuffer);
	
	if(!g_ClientMenuState[client][CMS_addZone])
		hMenu.AddItem("axismenu", "Move point on axes through menu");
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleZonePointEdit(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		if(StrEqual(sInfo, "save"))
		{
			SaveZonePointModifications(param1, group);
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
		
		bool bAdding = g_ClientMenuState[param1][CMS_addZone];
		g_ClientMenuState[param1][CMS_editCenter] = false;
		g_ClientMenuState[param1][CMS_editPosition] = false;
		g_ClientMenuState[param1][CMS_editState] = ZES_first;
		g_ClientMenuState[param1][CMS_redrawPointMenu] = false;
		ResetZoneAddingState(param1);
		if(param2 == MenuCancel_ExitBack)
		{
			// Only go back to the zone list if we aren't told to call the menucancel callback.
			if(bAdding && !TryCallMenuCancelForward(param1, param2))
				DisplayZoneListMenu(param1);
			else if (!bAdding)
				DisplayZoneEditDetailsMenu(param1);
		}
		else
		{
			TryCallMenuCancelForward(param1, param2);
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

void SaveZonePointModifications(int client, int group[ZoneGroup])
{
	int zoneData[ZoneData];
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	// Save the new center of the zone.
	// The rotation and mins/maxs stay the same, so not much to do.
	if(g_ClientMenuState[client][CMS_editCenter])
	{
		Array_Copy(g_ClientMenuState[client][CMS_center], zoneData[ZD_position], 3);
		g_ClientMenuState[client][CMS_editCenter] = false;
	}
	else
	{
		// Save the new position of one of the points.
		// Need to recalculate the center and mins/maxs now.
		SaveChangedZoneCoordinates(client, zoneData);
		Array_Copy(g_ClientMenuState[client][CMS_rotation], zoneData[ZD_rotation], 3);
		// Find a better fitting trigger model for the new zone
		// next time this zone is created.
		zoneData[ZD_triggerModel][0] = '\0';
		g_ClientMenuState[client][CMS_editPosition] = false;
		g_ClientMenuState[client][CMS_editState] = ZES_first;
	}
	
	SaveZone(group, zoneData);
	SetupZone(group, zoneData);
	
	ResetZoneAddingState(client);
	DisplayZoneEditDetailsMenu(client);
	TriggerTimer(g_hShowZonesTimer, true);
}

void DisplayPointAxisModificationMenu(int client)
{
	int group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	
	Menu hMenu = new Menu(Menu_HandlePointAxisEdit);
	hMenu.Pagination = MENU_NO_PAGINATION;
	
	char sBuffer[256];
	if(g_ClientMenuState[client][CMS_editCenter])
	{
		Format(sBuffer, sizeof(sBuffer), "Edit center of zone \"%s\"", zoneData[ZD_name]);
	}
	else
	{
		Format(sBuffer, sizeof(sBuffer), "Edit zone \"%s\" position %d", zoneData[ZD_name], view_as<int>(g_ClientMenuState[client][CMS_editState])+1);
	}
	Format(sBuffer, sizeof(sBuffer), "%s\nMove position along the axes.", sBuffer);
	hMenu.SetTitle(sBuffer);
	
	hMenu.AddItem("save", "Save changes");
	
	Format(sBuffer, sizeof(sBuffer), "Stepsize: %.0f\n \n", g_fStepsizes[g_ClientMenuState[client][CMS_stepSizeIndex]]);
	hMenu.AddItem("togglestepsize", sBuffer);

	hMenu.AddItem("ax", "Add to X axis (red)");
	hMenu.AddItem("sx", "Subtract from X axis");
	hMenu.AddItem("ay", "Add to Y axis (green)");
	hMenu.AddItem("sy", "Subtract from Y axis");
	hMenu.AddItem("az", "Add to Z axis (blue)");
	hMenu.AddItem("sz", "Subtract from Z axis\n \n");
	
	// Push the button number to the last in the menu.
	if (GetMaxPageItems(hMenu.Style) > 9)
		hMenu.AddItem("", "", ITEMDRAW_DISABLED|ITEMDRAW_SPACER);
	
	// Simulate our own back button..
	Format(sBuffer, sizeof(sBuffer), "%T", "Back", client);
	hMenu.AddItem("back", sBuffer);
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandlePointAxisEdit(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		if(StrEqual(sInfo, "save"))
		{
			int group[ZoneGroup];
			GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
			SaveZonePointModifications(param1, group);
			return;
		}
		
		if(StrEqual(sInfo, "togglestepsize"))
		{
			g_ClientMenuState[param1][CMS_stepSizeIndex] = (g_ClientMenuState[param1][CMS_stepSizeIndex] + 1) % sizeof(g_fStepsizes);
			DisplayPointAxisModificationMenu(param1);
			return;
		}
		
		if(StrEqual(sInfo, "back"))
		{
			g_ClientMenuState[param1][CMS_disablePreview] = false;
			DisplayZonePointEditMenu(param1);
			return;
		}
		
		// Add to x
		float fValue = g_fStepsizes[g_ClientMenuState[param1][CMS_stepSizeIndex]];
		if(sInfo[0] == 's')
			fValue *= -1.0;
		
		int iAxis = sInfo[1] - 'x';
		
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
		// See if we need to call the menu cancel forward, if this menu was opened by a plugin
		TryCallMenuCancelForward(param1, param2);
		
		g_ClientMenuState[param1][CMS_disablePreview] = false;
		g_ClientMenuState[param1][CMS_editCenter] = false;
		g_ClientMenuState[param1][CMS_editPosition] = false;
		g_ClientMenuState[param1][CMS_editState] = ZES_first;
		ResetZoneAddingState(param1);
		g_ClientMenuState[param1][CMS_zone] = -1;
		g_ClientMenuState[param1][CMS_cluster] = -1;
		g_ClientMenuState[param1][CMS_group] = -1;
	}
}

void DisplayZoneRotationMenu(int client)
{
	int group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	
	Menu hMenu = new Menu(Menu_HandleZoneRotation);
	hMenu.SetTitle("Rotate zone %s", zoneData[ZD_name]);
	hMenu.ExitBackButton = true;
	
	hMenu.AddItem("", "Hold \"e\" and move your mouse to rotate the box.", ITEMDRAW_DISABLED);
	hMenu.AddItem("", "Hold \"shift\" too, to rotate around a different axis when moving mouse up and down.", ITEMDRAW_DISABLED);
	
	hMenu.AddItem("save", "Save rotation");
	hMenu.AddItem("reset", "Reset rotation");
	hMenu.AddItem("discard", "Discard new rotation");
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleZoneRotation(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup], zoneData[ZoneData];
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
			TryCallMenuCancelForward(param1, param2);
			
			g_ClientMenuState[param1][CMS_zone] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			g_ClientMenuState[param1][CMS_group] = -1;
		}
	}
}

void DisplayZoneAddFinalizationMenu(int client)
{
	if(g_ClientMenuState[client][CMS_group] == -1)
		return;
	
	int group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	
	Menu hMenu = new Menu(Menu_HandleAddFinalization);
	if(g_ClientMenuState[client][CMS_cluster] == -1)
		hMenu.SetTitle("Save new zone in group \"%s\"?", group[ZG_name]);
	else
	{
		int zoneCluster[ZoneCluster];
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
		hMenu.SetTitle("Save new zone in cluster \"%s\" of group \"%s\"?", zoneCluster[ZC_name], group[ZG_name]);
	}
	hMenu.ExitBackButton = true;
	
	char sBuffer[128];
	// When pasting a zone we want to edit the center position afterwards right away.
	if(g_ClientMenuState[client][CMS_editCenter])
	{
		Format(sBuffer, sizeof(sBuffer), "Pasting new copy of zone \"%s\".\nYou can place the copy after giving it a name.", g_Clipboard[client][CB_name]);
		hMenu.AddItem("", sBuffer, ITEMDRAW_DISABLED);
	}
	
	hMenu.AddItem("", "Type zone name in chat to save it. (\"!abort\" to abort)", ITEMDRAW_DISABLED);
	
	GetFreeAutoZoneName(group, sBuffer, sizeof(sBuffer));
	Format(sBuffer, sizeof(sBuffer), "Use auto-generated zone name (%s)", sBuffer);
	hMenu.AddItem("autoname", sBuffer);
	hMenu.AddItem("discard", "Discard new zone");
	
	hMenu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_HandleAddFinalization(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_End)
	{
		delete menu;
	}
	else if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		int group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[param1][CMS_group], group);
		
		// Add the zone using a generated name
		if(StrEqual(sInfo, "autoname"))
		{
			char sBuffer[128];
			GetFreeAutoZoneName(group, sBuffer, sizeof(sBuffer));
			SaveNewZone(param1, sBuffer);
		}
		// delete the zone
		else if(StrEqual(sInfo, "discard"))
		{
			ResetZoneAddingState(param1);
			// In case we were pasting a zone from clipboard.
			g_ClientMenuState[param1][CMS_editCenter] = false;
			
			// Don't open our own menus if we're supposed to call the menu cancel callback.
			if (TryCallMenuCancelForward(param1, MenuCancel_ExitBack))
				return;
			
			if(g_ClientMenuState[param1][CMS_cluster] == -1)
				DisplayZoneListMenu(param1);
			else
				DisplayClusterEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		ResetZoneAddingState(param1);
		
		// Don't open our own menus if we're supposed to call the menu cancel callback.
		if (g_ClientMenuState[param1][CMS_zone] == -1
		&& TryCallMenuCancelForward(param1, param2))
		{
			// In case we were pasting a zone from clipboard.
			g_ClientMenuState[param1][CMS_editCenter] = false;
			g_ClientMenuState[param1][CMS_group] = -1;
			g_ClientMenuState[param1][CMS_cluster] = -1;
			return;
		}
		
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

bool TryCallMenuCancelForward(int client, int cancelReason)
{
	// See if we need to call the menu cancel forward, if this menu was opened by a plugin
	if (!g_ClientMenuState[client][CMS_backToMenuAfterEdit])
		return false;
	
	// Reset this state again, so we can navigate the menu normally.
	g_ClientMenuState[client][CMS_backToMenuAfterEdit] = false;
	
	int group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	// No cancel callback registered for this group?
	if (!group[ZG_menuCancelForward])
		return false;
	
	// Call the forward in the other plugin.
	Call_StartForward(group[ZG_menuCancelForward]);
	Call_PushCell(client);
	Call_PushCell(cancelReason);
	Call_PushString(group[ZG_name]);
	Call_Finish();
	return true;
}

/**
 * Zone information persistence in configs
 */
void LoadAllGroupZones()
{
	int group[ZoneGroup];
	int iSize = g_hZoneGroups.Length;
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		LoadZoneGroup(group);
	}
}

bool LoadZoneGroup(group[ZoneGroup])
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/mapzonelib/%s/%s.zones", group[ZG_name], g_sCurrentMap);
	
	if(!FileExists(sPath))
		return false;
	
	KeyValues hKV = new KeyValues("MapZoneGroup");
	if(!hKV)
		return false;
	
	// Allow \" and \n escapeing
	hKV.SetEscapeSequences(true);
	
	if(!hKV.ImportFromFile(sPath))
		return false;
	
	if(!hKV.GotoFirstSubKey())
		return false;
	
	float vBuf[3];
	char sBuffer[32], sZoneName[MAX_ZONE_NAME];
	int zoneCluster[ZoneCluster];
	zoneCluster[ZC_index] = -1;
	
	do {
		hKV.GetSectionName(sBuffer, sizeof(sBuffer));
		// This is the start of a cluster group.
		if(!StrContains(sBuffer, "cluster", false))
		{
			// A cluster in a cluster? nope..
			if(zoneCluster[ZC_index] != -1)
				continue;
			
			// Get the cluster name
			hKV.GetString("name", sZoneName, sizeof(sZoneName), "unnamed");
			strcopy(zoneCluster[ZC_name][0], MAX_ZONE_NAME, sZoneName);
			zoneCluster[ZC_teamFilter] = hKV.GetNum("team");
			
			int iColor[4];
			hKV.GetColor("color", iColor[0], iColor[1], iColor[2], iColor[3]);
			if (iColor[0] == 0 && iColor[1] == 0 && iColor[2] == 0 && iColor[3] == 0)
				Array_Fill(iColor, sizeof(iColor), -1);
			Array_Copy(iColor, zoneCluster[ZC_color], sizeof(iColor));
			
			// See if there is a custom keyvalues section for this cluster.
			if(hKV.JumpToKey("custom", false) && hKV.GotoFirstSubKey(false))
			{
				zoneCluster[ZC_customKV] = new StringMap();
				ParseCustomKeyValues(hKV, zoneCluster[ZC_customKV]);
				hKV.GoBack(); // KvGotoFirstSubKey
				hKV.GoBack(); // KvJumpToKey
			}
			
			zoneCluster[ZC_index] = group[ZG_cluster].Length;
			group[ZG_cluster].PushArray(zoneCluster[0], view_as<int>(ZoneCluster));
			
			// Step inside this group
			hKV.GotoFirstSubKey();
		}
		
		// Don't parse the custom section as a zone of a cluster.
		hKV.GetSectionName(sBuffer, sizeof(sBuffer));
		if (StrEqual(sBuffer, "custom", false))
			continue;
		
		int zoneData[ZoneData];
		hKV.GetVector("pos", vBuf);
		Array_Copy(vBuf, zoneData[ZD_position], 3);
		
		hKV.GetVector("mins", vBuf);
		Array_Copy(vBuf, zoneData[ZD_mins], 3);
		
		hKV.GetVector("maxs", vBuf);
		Array_Copy(vBuf, zoneData[ZD_maxs], 3);
		
		hKV.GetVector("rotation", vBuf);
		Array_Copy(vBuf, zoneData[ZD_rotation], 3);
		
		zoneData[ZD_teamFilter] = hKV.GetNum("team");
		
		int iColor[4];
		hKV.GetColor("color", iColor[0], iColor[1], iColor[2], iColor[3]);
		if (iColor[0] == 0 && iColor[1] == 0 && iColor[2] == 0 && iColor[3] == 0)
				Array_Fill(iColor, sizeof(iColor), -1);
		Array_Copy(iColor, zoneData[ZD_color], sizeof(iColor));
		
		hKV.GetString("name", sZoneName, sizeof(sZoneName), "unnamed");
		strcopy(zoneData[ZD_name][0], MAX_ZONE_NAME, sZoneName);
		
		// See if there is a custom keyvalues section for this zone.
		// Step inside.
		if(hKV.JumpToKey("custom", false) && hKV.GotoFirstSubKey(false))
		{
			//if(zoneCluster[ZC_index] != -1)
			//{
			//	LogError("No custom keyvalues allowed in individual cluster zones (%s, %s, %s)", group[ZG_name], zoneCluster[ZC_name], zoneData[ZD_name]);
			//}
			zoneData[ZD_customKV] = new StringMap();
			ParseCustomKeyValues(hKV, zoneData[ZD_customKV]);
			hKV.GoBack(); // KvGotoFirstSubKey
			hKV.GoBack(); // KvJumpToKey
		}
		
		zoneData[ZD_clusterIndex] = zoneCluster[ZC_index];
		
		zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
		zoneData[ZD_index] = group[ZG_zones].Length;
		group[ZG_zones].PushArray(zoneData[0], view_as<int>(ZoneData));
		
		// Step out of the cluster group if we reached the end.
		hKV.SavePosition();
		if(!hKV.GotoNextKey() && zoneCluster[ZC_index] != -1)
		{
			zoneCluster[ZC_index] = -1;
			hKV.GoBack();
		}
		hKV.GoBack();
		
	} while(hKV.GotoNextKey());
	
	delete hKV;
	
	// Inform all other plugins that these zones and clusters exist now.
	CallOnCreatedForAllInGroup(group);
	
	return true;
}

void ParseCustomKeyValues(KeyValues hKV, StringMap hCustomKV)
{
	char sKey[128], sValue[256];
	do
	{
		hKV.GetSectionName(sKey, sizeof(sKey));
		hKV.GetString(NULL_STRING, sValue, sizeof(sValue));
		hCustomKV.SetString(sKey, sValue, true);
	} while (hKV.GotoNextKey(false));
}

// Save the zones to the config files and optionally to the database too.
void SaveAllZoneGroups()
{
	SaveAllZoneGroupsToFile();
	if (g_hDatabase)
		SaveAllZoneGroupsToDatabase();
}

void SaveAllZoneGroupsToFile()
{
	int group[ZoneGroup];
	int iSize = g_hZoneGroups.Length;
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		if(!SaveZoneGroupToFile(group))
			LogError("Error creating \"configs/mapzonelib/%s/\" folder. Didn't save any zones in that group.", group[ZG_name]);
	}
}

bool SaveZoneGroupToFile(int group[ZoneGroup])
{
	char sPath[PLATFORM_MAX_PATH];
	int iMode = FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC|FPERM_G_READ|FPERM_G_WRITE|FPERM_G_EXEC|FPERM_O_READ|FPERM_O_EXEC;
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
	
	KeyValues hKV = new KeyValues("MapZoneGroup");
	if(!hKV)
		return false;
	
	// Allow \" and \n escapeing
	hKV.SetEscapeSequences(true);
	
	// Add all zones of this group to the keyvalues file.
	// Add normal zones without a cluster first.
	bool bZonesAdded = CreateZoneSectionsInKV(hKV, group, -1);
	
	int iNumClusters = group[ZG_cluster].Length;
	int zoneCluster[ZoneCluster], iIndex;
	char sIndex[32];
	for(int i=0;i<iNumClusters;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		if(zoneCluster[ZC_deleted])
			continue;
		
		Format(sIndex, sizeof(sIndex), "cluster%d", iIndex++);
		hKV.JumpToKey(sIndex, true);
		hKV.SetString("name", zoneCluster[ZC_name]);
		hKV.SetNum("team", zoneCluster[ZC_teamFilter]);
		// Only set the color to the KV if it was set.
		if (zoneCluster[ZC_color][0] >= 0)
			hKV.SetColor("color", zoneCluster[ZC_color][0], zoneCluster[ZC_color][1], zoneCluster[ZC_color][2], zoneCluster[ZC_color][3]);
		
		AddCustomKeyValues(hKV, zoneCluster[ZC_customKV]);
		
		// Run through all zones and add the ones that belong to this cluster.
		bZonesAdded |= CreateZoneSectionsInKV(hKV, group, zoneCluster[ZC_index]);
		
		hKV.GoBack();
	}
	
	hKV.Rewind();
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/mapzonelib/%s/%s.zones", group[ZG_name], g_sCurrentMap);
	// Only add zones, if there are any for this map.
	if(bZonesAdded)
	{
		if(!hKV.ExportToFile(sPath))
			LogError("Error saving zones to file %s.", sPath);
	}
	else
	{
		// Remove the zone config otherwise, so we don't keep empty files around.
		DeleteFile(sPath);
	}
	delete hKV;
	
	return true;
}

bool CreateZoneSectionsInKV(KeyValues hKV, int group[ZoneGroup], int iClusterIndex)
{
	char sIndex[16], sColor[64];
	int zoneData[ZoneData], iIndex;
	float vBuf[3];
	int iSize = group[ZG_zones].Length;
	bool bZonesAdded;
	for(int i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		// Does this belong to the right cluster?
		if(zoneData[ZD_clusterIndex] != iClusterIndex)
			continue;
		
		bZonesAdded = true;
		
		IntToString(iIndex++, sIndex, sizeof(sIndex));
		hKV.JumpToKey(sIndex, true);
		
		Array_Copy(zoneData[ZD_position], vBuf, 3);
		hKV.SetVector("pos", vBuf);
		Array_Copy(zoneData[ZD_mins], vBuf, 3);
		hKV.SetVector("mins", vBuf);
		Array_Copy(zoneData[ZD_maxs], vBuf, 3);
		hKV.SetVector("maxs", vBuf);
		Array_Copy(zoneData[ZD_rotation], vBuf, 3);
		hKV.SetVector("rotation", vBuf);
		hKV.SetNum("team", zoneData[ZD_teamFilter]);
		// Only set the color to the KV if it was set.
		if (zoneData[ZD_color][0] >= 0)
		{
			Format(sColor, sizeof(sColor), "%d %d %d %d", zoneData[ZD_color][0], zoneData[ZD_color][1], zoneData[ZD_color][2], zoneData[ZD_color][3]);
			// KvSetColor isn't implemented in the SDK when saving to file.
			hKV.SetString("color", sColor);
		}
		hKV.SetString("name", zoneData[ZD_name]);
		
		AddCustomKeyValues(hKV, zoneData[ZD_customKV]);
		
		hKV.GoBack();
	}
	
	return bZonesAdded;
}

void AddCustomKeyValues(KeyValues hKV, StringMap hCustomKV)
{
	if (hCustomKV == INVALID_HANDLE || hCustomKV.Size == 0)
		return;
	
	hKV.JumpToKey("custom", true);
	
	StringMapSnapshot hTrieSnapshot = hCustomKV.Snapshot();
	
	int iSize = hTrieSnapshot.Length;
	char sKey[128], sValue[256];
	for (int i=0; i<iSize; i++)
	{
		hTrieSnapshot.GetKey(i, sKey, sizeof(sKey));
		hCustomKV.GetString(sKey, sValue, sizeof(sValue));
		hKV.SetString(sKey, sValue);
	}
	
	delete hTrieSnapshot;
	hKV.GoBack();
}

/**
 * SQL zone handling
 * This is optional and only active when setting the sm_mapzone_database_config convar.
 */
public void SQL_OnConnect(Database db, const char[] error, any data)
{
	if (!db)
	{
		LogError("Error connecting to database: %s", error);
		g_bConnectingToDatabase = false;
		// Load the zones from the config files.
		LoadAllGroupZones();
		// Spawn the trigger_multiples for all zones
		SetupAllGroupZones();
		return;
	}
	
	g_hDatabase = db;
	
	// Check if there are our tables in the database already.
	char sQuery[1024];
	Format(sQuery, sizeof(sQuery), "SELECT COUNT(*) FROM `%sclusters`", g_sTablePrefix);
	g_hDatabase.Query(SQL_CheckTables, sQuery);
}

public void SQL_CheckTables(Database db, DBResultSet results, const char[] error, any data)
{
	// Tables exists.
	if (results)
	{
		LoadAllGroupZonesFromDatabase(++g_iDatabaseSequence);
		return;
	}
	
	char sQuery[1024];
	Transaction hTransaction = new Transaction();
	Format(sQuery, sizeof(sQuery), "CREATE TABLE `%sclusters` (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, groupname VARCHAR(64) NOT NULL, map VARCHAR(128) NOT NULL, name VARCHAR(64) NOT NULL, team INT DEFAULT 0, color INT DEFAULT 0, CONSTRAINT cluster_in_group UNIQUE (groupname, map, name))", g_sTablePrefix);
	hTransaction.AddQuery(sQuery);
	
	Format(sQuery, sizeof(sQuery), "CREATE TABLE `%szones` (id INT NOT NULL AUTO_INCREMENT, cluster_id INT NULL, groupname VARCHAR(64) NOT NULL, map VARCHAR(128) NOT NULL, name VARCHAR(64) NOT NULL, pos_x FLOAT NOT NULL, pos_y FLOAT NOT NULL, pos_z FLOAT NOT NULL, min_x FLOAT NOT NULL, min_y FLOAT NOT NULL, min_z FLOAT NOT NULL, max_x FLOAT NOT NULL, max_y FLOAT NOT NULL, max_z FLOAT NOT NULL, rotation_x FLOAT NOT NULL, rotation_y FLOAT NOT NULL, rotation_z FLOAT NOT NULL, team INT DEFAULT 0, color INT DEFAULT 0, PRIMARY KEY (id), FOREIGN KEY (cluster_id) REFERENCES `%sclusters`(id) ON DELETE CASCADE, CONSTRAINT zone_in_group UNIQUE (groupname, map, name))", g_sTablePrefix, g_sTablePrefix);
	hTransaction.AddQuery(sQuery);
	
	Format(sQuery, sizeof(sQuery), "CREATE FULLTEXT INDEX mapgroup on `%szones` (groupname, map)", g_sTablePrefix);
	hTransaction.AddQuery(sQuery);
	
	Format(sQuery, sizeof(sQuery), "CREATE FULLTEXT INDEX mapgroup on `%sclusters` (groupname, map)", g_sTablePrefix);
	hTransaction.AddQuery(sQuery);
	
	Format(sQuery, sizeof(sQuery), "CREATE TABLE `%scustom_zone_keyvalues` (zone_id INT NOT NULL, setting VARCHAR(128) NOT NULL, val VARCHAR(256) NOT NULL, PRIMARY KEY (zone_id, setting), FOREIGN KEY (zone_id) REFERENCES `%szones`(id) ON DELETE CASCADE)", g_sTablePrefix, g_sTablePrefix);
	hTransaction.AddQuery(sQuery);
	
	Format(sQuery, sizeof(sQuery), "CREATE TABLE `%scustom_cluster_keyvalues` (cluster_id INT NOT NULL, setting VARCHAR(128) NOT NULL, val VARCHAR(256) NOT NULL, PRIMARY KEY (cluster_id, setting), FOREIGN KEY (cluster_id) REFERENCES `%sclusters`(id) ON DELETE CASCADE)", g_sTablePrefix, g_sTablePrefix);
	hTransaction.AddQuery(sQuery);
	
	g_hDatabase.Execute(hTransaction, SQLTxn_CreateTablesSuccess, SQLTxn_CreateTablesFailure);
}

public void SQLTxn_CreateTablesSuccess(Database db, any data, int numQueries, Handle[] results, any[] queryData)
{
	// Nothing to load here :)
}

public void SQLTxn_CreateTablesFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("Error creating database tables (%d/%d). Falling back to local config files. Error: %s", failIndex, numQueries, error);
	// Cannot use this database..
	if (db)
		delete db;
	g_hDatabase = null;
	
	// Remove all zones.
	ClearZonesInGroups();
	// Load the zones from the config files.
	LoadAllGroupZones();
	// Spawn the trigger_multiples for all zones
	SetupAllGroupZones();
}

// Used in any error condition while loading maps from the database.
void LoadZonesFromConfigsInstead(int group[ZoneGroup])
{
	// Remove zones of this group before that might already been loaded.
	ClearZonesinGroup(group);
	// Load the zones of this group.
	LoadZoneGroup(group);
	// Spawn the trigger_multiples for these zones
	SetupGroupZones(group);
}

void LoadAllGroupZonesFromDatabase(int iSequence)
{
	int group[ZoneGroup];
	int iSize = g_hZoneGroups.Length;
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		LoadZoneGroupFromDatabase(group, iSequence);
	}
}

void LoadZoneGroupFromDatabase(int group[ZoneGroup], int iSequence)
{
	char sMapEscaped[257], sGroupNameEscaped[MAX_ZONE_GROUP_NAME*2+1];
	g_hDatabase.Escape(g_sCurrentMap, sMapEscaped, sizeof(sMapEscaped));
	g_hDatabase.Escape(group[ZG_name], sGroupNameEscaped, sizeof(sGroupNameEscaped));
	
	// First get all the clusters.
	char sQuery[512];
	Format(sQuery, sizeof(sQuery), "SELECT id, name, team, color FROM `%sclusters` WHERE groupname = '%s' AND map = '%s'", g_sTablePrefix, sGroupNameEscaped, sMapEscaped);
	DataPack hPack = new DataPack();
	hPack.WriteCell(iSequence);
	hPack.WriteCell(group[ZG_index]);
	g_hDatabase.Query(SQL_GetClusters, sQuery, hPack);
}

public void SQL_GetClusters(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int iSequence = data.ReadCell();
	int iGroupIndex = data.ReadCell();
	// This is old data. Discard everything.
	if (iSequence != g_iDatabaseSequence)
	{
		delete data;
		return;
	}
	
	int group[ZoneGroup];
	GetGroupByIndex(iGroupIndex, group);
	
	if (!results)
	{
		LogError("Failed to get clusters: %s", error);
		delete data;
		LoadZonesFromConfigsInstead(group);
		return;
	}
	
	// SELECT id, name, team, color
	char sClusterIDs[1024];
	int zoneCluster[ZoneCluster], iColorInt;
	while (results.FetchRow())
	{
		zoneCluster[ZC_databaseId] = results.FetchInt(0);
		results.FetchString(1, zoneCluster[ZC_name], MAX_ZONE_NAME);
		zoneCluster[ZC_teamFilter] = results.FetchInt(2);
		iColorInt = results.FetchInt(3);
		zoneCluster[ZC_color][0] = (iColorInt >> 24) & 0xff;
		zoneCluster[ZC_color][1] = (iColorInt >> 16) & 0xff;
		zoneCluster[ZC_color][2] = (iColorInt >> 8) & 0xff;
		zoneCluster[ZC_color][3] = iColorInt & 0xff;
		
		zoneCluster[ZC_index] = group[ZG_cluster].Length;
		group[ZG_cluster].PushArray(zoneCluster[0], view_as<int>(ZoneCluster));
		
		// Save all loaded cluster ids so we can load the custom keyvalues for them
		if (sClusterIDs[0])
			Format(sClusterIDs, sizeof(sClusterIDs), "%s, %d", sClusterIDs, zoneCluster[ZC_databaseId]);
		else
			Format(sClusterIDs, sizeof(sClusterIDs), "%d", zoneCluster[ZC_databaseId]);
	}
	
	// No clusters in this group. This will return 0 results.
	if (!sClusterIDs[0])
		sClusterIDs = "-1"; // FIXME Save this query and go right to the next step if there are no clusters.
	
	// Now load all the custom key values for these clusters.
	char sQuery[2048];
	Format(sQuery, sizeof(sQuery), "SELECT cluster_id, setting, val FROM `%scustom_cluster_keyvalues` WHERE cluster_id IN(%s)", g_sTablePrefix, sClusterIDs);
	g_hDatabase.Query(SQL_GetClusterKeyValues, sQuery, data);
}

public void SQL_GetClusterKeyValues(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int iSequence = data.ReadCell();
	int iGroupIndex = data.ReadCell();
	// This is old data. Discard everything.
	if (iSequence != g_iDatabaseSequence)
	{
		delete data;
		return;
	}
	
	int group[ZoneGroup];
	GetGroupByIndex(iGroupIndex, group);
	
	if (!results)
	{
		LogError("Failed to get cluster key values: %s", error);
		delete data;
		LoadZonesFromConfigsInstead(group);
		return;
	}
	
	// SELECT cluster_id, setting, val
	int zoneCluster[ZoneCluster], iClusterIndex;
	char sKey[64], sValue[64];
	while (results.FetchRow())
	{
		iClusterIndex = group[ZG_cluster].FindValue(results.FetchInt(0), view_as<int>(ZC_databaseId));
		if (iClusterIndex == -1)
			continue;
		
		GetZoneClusterByIndex(iClusterIndex, group, zoneCluster);
		if (!zoneCluster[ZC_customKV])
		{
			zoneCluster[ZC_customKV] = new StringMap();
			SaveCluster(group, zoneCluster);
		}
		
		results.FetchString(1, sKey, sizeof(sKey));
		results.FetchString(2, sValue, sizeof(sValue));
		zoneCluster[ZC_customKV].SetString(sKey, sValue);
	}
	
	char sMapEscaped[257], sGroupNameEscaped[MAX_ZONE_GROUP_NAME*2+1];
	g_hDatabase.Escape(g_sCurrentMap, sMapEscaped, sizeof(sMapEscaped));
	g_hDatabase.Escape(group[ZG_name], sGroupNameEscaped, sizeof(sGroupNameEscaped));
	
	// Now get all the zones in that group.
	char sQuery[1024];
	Format(sQuery, sizeof(sQuery), "SELECT id, cluster_id, name, pos_x, pos_y, pos_z, min_x, min_y, min_z, max_x, max_y, max_z, rotation_x, rotation_y, rotation_z, team, color FROM `%szones` WHERE groupname = '%s' AND map = '%s'", g_sTablePrefix, sGroupNameEscaped, sMapEscaped);
	g_hDatabase.Query(SQL_GetZones, sQuery, data);
}

public void SQL_GetZones(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int iSequence = data.ReadCell();
	int iGroupIndex = data.ReadCell();
	// This is old data. Discard everything.
	if (iSequence != g_iDatabaseSequence)
	{
		delete data;
		return;
	}
	
	int group[ZoneGroup];
	GetGroupByIndex(iGroupIndex, group);
	
	if (!results)
	{
		LogError("Failed to get zones: %s", error);
		delete data;
		LoadZonesFromConfigsInstead(group);
		return;
	}
	
	// SELECT id, cluster_id, name, pos_x, pos_y, pos_z, min_x, min_y, min_z, max_x, max_y, max_z, rotation_x, rotation_y, rotation_z, team, color
	char sZoneIDs[1024];
	int zoneData[ZoneData], iColorInt;
	while (results.FetchRow())
	{
		zoneData[ZD_databaseId] = results.FetchInt(0);
		zoneData[ZD_clusterIndex] = group[ZG_cluster].FindValue(results.FetchInt(1), view_as<int>(ZC_databaseId));
		results.FetchString(2, zoneData[ZD_name], MAX_ZONE_NAME);
		for (int i=0; i<3; i++)
		{
			zoneData[ZD_position][i] = results.FetchFloat(i+3);
			zoneData[ZD_mins][i] = results.FetchFloat(i+6);
			zoneData[ZD_maxs][i] = results.FetchFloat(i+9);
			zoneData[ZD_rotation][i] = results.FetchFloat(i+12);
		}
		zoneData[ZD_teamFilter] = results.FetchInt(15);
		iColorInt = results.FetchInt(16);
		zoneData[ZD_color][0] = (iColorInt >> 24) & 0xff;
		zoneData[ZD_color][1] = (iColorInt >> 16) & 0xff;
		zoneData[ZD_color][2] = (iColorInt >> 8) & 0xff;
		zoneData[ZD_color][3] = iColorInt & 0xff;
		
		zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
		zoneData[ZD_index] = group[ZG_zones].Length;
		group[ZG_zones].PushArray(zoneData[0], view_as<int>(ZoneData));
		
		// Save all loaded zone ids so we can load the custom keyvalues for them
		if (sZoneIDs[0])
			Format(sZoneIDs, sizeof(sZoneIDs), "%s, %d", sZoneIDs, zoneData[ZD_databaseId]);
		else
			Format(sZoneIDs, sizeof(sZoneIDs), "%d", zoneData[ZD_databaseId]);
	}
	
	// No clusters in this group. This will return 0 results.
	if (!sZoneIDs[0])
		sZoneIDs = "-1";  // FIXME Save this query and go right to the next step if there are no zones.
	
	// Now load all the custom key values for these clusters.
	char sQuery[2048];
	Format(sQuery, sizeof(sQuery), "SELECT zone_id, setting, val FROM `%scustom_zone_keyvalues` WHERE zone_id IN(%s)", g_sTablePrefix, sZoneIDs);
	g_hDatabase.Query(SQL_GetZoneKeyValues, sQuery, data);
}

public void SQL_GetZoneKeyValues(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int iSequence = data.ReadCell();
	int iGroupIndex = data.ReadCell();
	delete data;
	
	// This is old data. Discard everything.
	if (iSequence != g_iDatabaseSequence)
	{
		return;
	}
	
	int group[ZoneGroup];
	GetGroupByIndex(iGroupIndex, group);
	
	if (!results)
	{
		LogError("Failed to get zones key values: %s", error);
		LoadZonesFromConfigsInstead(group);
		return;
	}
	
	// SELECT zone_id, setting, val
	int zoneData[ZoneData], iZoneIndex;
	char sKey[64], sValue[64];
	while (results.FetchRow())
	{
		iZoneIndex = group[ZG_zones].FindValue(results.FetchInt(0), view_as<int>(ZD_databaseId));
		if (iZoneIndex == -1)
			continue;
		
		GetZoneByIndex(iZoneIndex, group, zoneData);
		if (!zoneData[ZD_customKV])
		{
			zoneData[ZD_customKV] = new StringMap();
			SaveZone(group, zoneData);
		}
		
		results.FetchString(1, sKey, sizeof(sKey));
		results.FetchString(2, sValue, sizeof(sValue));
		zoneData[ZD_customKV].SetString(sKey, sValue);
	}
	
	// Spawn the trigger_multiples for all zones
	SetupGroupZones(group);
	
	// Inform other plugins that all the zones and clusters of this group are here now.
	CallOnCreatedForAllInGroup(group);
}

public void SQL_LogError(Database db, DBResultSet results, const char[] error, any data)
{
	if (!results)
	{
		LogError("Query failed: %s", error);
	}
}

void SaveAllZoneGroupsToDatabase()
{
	if (!g_hDatabase)
		return;
	
	int group[ZoneGroup];
	int iSize = g_hZoneGroups.Length;
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		SaveZoneGroupToDatabase(group);
	}
}

void SaveZoneGroupToDatabase(int group[ZoneGroup])
{
	// TODO: Optimize to only update clusters or zones that were changed during this map.
	// So don't change the database if the server only used the zones.
	Transaction hTransaction = new Transaction();
	// Zones and clusters
	int zoneData[ZoneData], zoneCluster[ZoneCluster];
	char sQuery[2048], sEscapedGroupName[MAX_ZONE_GROUP_NAME*2+1], sEscapedZoneName[MAX_ZONE_NAME*2+1], sClusterInsert[512];
	int iColor;
	
	// Custom keyvalues
	StringMapSnapshot hTrieSnapshot;
	int iNumTrieKeys;
	char sKey[128], sValue[256];
	char sEscapedKey[sizeof(sKey)*2+1], sEscapedValue[sizeof(sValue)*2+1];
	
	// Insert new clusters first.
	char sClustersToDelete[1024];
	g_hDatabase.Escape(group[ZG_name], sEscapedGroupName, sizeof(sEscapedGroupName));
	int iNumClusters = group[ZG_cluster].Length;
	for(int i=0;i<iNumClusters;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		// That cluster was deleted.
		// We cannot deal with that yet, because we might need to update the containing zones first.
		if(zoneCluster[ZC_deleted])
		{
			// Keep track of the deleted clusters, so we don't have to loop again when deleting them after updating zones.
			if (zoneCluster[ZC_databaseId] > 0)
			{
				if (sClustersToDelete[0])
					Format(sClustersToDelete, sizeof(sClustersToDelete), "%s, %d", sClustersToDelete, zoneCluster[ZC_databaseId]);
				else
					Format(sClustersToDelete, sizeof(sClustersToDelete), "%d", zoneCluster[ZC_databaseId]);
			}
			continue;
		}
		
		g_hDatabase.Escape(zoneCluster[ZC_name], sEscapedZoneName, sizeof(sEscapedZoneName));
		
		iColor = zoneCluster[ZC_color][0] << 24;
		iColor |= zoneCluster[ZC_color][1] << 16;
		iColor |= zoneCluster[ZC_color][2] << 8;
		iColor |= zoneCluster[ZC_color][3];
		
		// Update previous cluster.
		if (zoneCluster[ZC_databaseId] > 0)
		{
			Format(sQuery, sizeof(sQuery), "UPDATE `%sclusters` SET name = '%s', team = %d, color = %d WHERE id = %d", g_sTablePrefix, sEscapedZoneName, zoneCluster[ZC_teamFilter], iColor, zoneCluster[ZC_databaseId]);
			// Remember how to reference this cluster for the custom key values.
			Format(sClusterInsert, sizeof(sClusterInsert), "%d", zoneCluster[ZC_databaseId]);
		}
		// Or insert a new one.
		else
		{
			Format(sQuery, sizeof(sQuery), "INSERT INTO `%sclusters` (groupname, map, name, team, color) VALUES ('%s', '%s', '%s', %d, %d)", g_sTablePrefix, sEscapedGroupName, g_sCurrentMap, sEscapedZoneName, zoneCluster[ZC_teamFilter], iColor);
			// This cluster isn't in the database yet, so we need to fetch the id after it got inserted for the custom keyvalues.
			Format(sClusterInsert, sizeof(sClusterInsert), "(SELECT id FROM `%sclusters` WHERE groupname = '%s' AND map = '%s' AND name = '%s')", g_sTablePrefix, sEscapedGroupName, g_sCurrentMap, sEscapedZoneName);
		}
		hTransaction.AddQuery(sQuery);
		
		// Insert custom key values if there was something set.
		if (!zoneCluster[ZC_customKVChanged] || !zoneCluster[ZC_customKV])
			continue;
		
		// Have to remove all kv first
		// This is much easier than tracking which key got deleted.
		Format(sQuery, sizeof(sQuery), "DELETE FROM `%scustom_cluster_keyvalues` WHERE cluster_id = %d", g_sTablePrefix, zoneCluster[ZC_databaseId]);
		hTransaction.AddQuery(sQuery);
		
		hTrieSnapshot = zoneCluster[ZC_customKV].Snapshot();
		iNumTrieKeys = hTrieSnapshot.Length;
		for (int k=0; k<iNumTrieKeys; k++)
		{
			hTrieSnapshot.GetKey(k, sKey, sizeof(sKey));
			zoneCluster[ZC_customKV].GetString(sKey, sValue, sizeof(sValue));
			g_hDatabase.Escape(sKey, sEscapedKey, sizeof(sEscapedKey));
			g_hDatabase.Escape(sValue, sEscapedValue, sizeof(sEscapedValue));
			Format(sQuery, sizeof(sQuery), "INSERT INTO `%scustom_cluster_keyvalues` (cluster_id, setting, val) VALUES (%s, '%s', '%s')", g_sTablePrefix, sClusterInsert, sEscapedKey, sEscapedValue);
			hTransaction.AddQuery(sQuery);
		}
		delete hTrieSnapshot;
	}
	// Update all clusters at once.
	g_hDatabase.Execute(hTransaction, SQLTxn_InsertSuccess, SQLTxn_InsertClusterFailure);
	
	// Update all zones now.
	hTransaction = new Transaction();
	int iNumZones = group[ZG_zones].Length;
	char sZoneInsert[512];
	for (int i=0; i<iNumZones; i++)
	{
		GetZoneByIndex(i, group, zoneData);
		// This zone is history.
		if (zoneData[ZD_deleted])
		{
			// We never had this in the database.
			// Nevermind :)
			if (zoneData[ZD_databaseId] <= 0)
				continue;
			
			Format(sQuery, sizeof(sQuery), "DELETE FROM `%szones` WHERE id = %d", g_sTablePrefix, zoneData[ZD_databaseId]);
			hTransaction.AddQuery(sQuery);
			continue;
		}
		
		// Does this belong to the right cluster?
		if(zoneData[ZD_clusterIndex] != -1)
		{
			GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
			
			// We just inserted this new cluster. It isn't in the database yet.
			if (zoneCluster[ZC_databaseId] <= 0)
			{
				// Find the previously inserted cluster id.
				g_hDatabase.Escape(zoneCluster[ZC_name], sEscapedZoneName, sizeof(sEscapedZoneName));
				Format(sClusterInsert, sizeof(sClusterInsert), "(SELECT id FROM `%sclusters` WHERE groupname = '%s' AND map = '%s' AND name = '%s')", g_sTablePrefix, sEscapedGroupName, g_sCurrentMap, sEscapedZoneName);
			}
			else
			{
				Format(sClusterInsert, sizeof(sClusterInsert), "%d", zoneCluster[ZC_databaseId]);
			}
		}
		// This zone doesn't blong to any cluster.
		else
		{
			sClusterInsert = "NULL";
		}
		
		// Pack color into one integer.
		iColor = zoneData[ZD_color][0] << 24;
		iColor |= zoneData[ZD_color][1] << 16;
		iColor |= zoneData[ZD_color][2] << 8;
		iColor |= zoneData[ZD_color][3];
		
		g_hDatabase.Escape(zoneData[ZD_name], sEscapedZoneName, sizeof(sEscapedZoneName));
		
		// Update or insert the zone.
		if (zoneData[ZD_databaseId] <= 0)
		{
			Format(sQuery, sizeof(sQuery), "INSERT INTO `%szones` (cluster_id, groupname, map, name, pos_x, pos_y, pos_z, min_x, min_y, min_z, max_x, max_y, max_z, rotation_x, rotation_y, rotation_z, team, color) VALUES (%s, '%s', '%s', '%s', %f, %f, %f, %f, %f, %f, %f, %f, %f, %f, %f, %f, %d, %d)", g_sTablePrefix, sClusterInsert, sEscapedGroupName, g_sCurrentMap, sEscapedZoneName, XYZ(zoneData[ZD_position]), XYZ(zoneData[ZD_mins]), XYZ(zoneData[ZD_maxs]), XYZ(zoneData[ZD_rotation]), zoneData[ZD_teamFilter], iColor);
			
			// This zone isn't in the database yet, so we need to fetch the id after it got inserted for the custom keyvalues.
			Format(sZoneInsert, sizeof(sZoneInsert), "(SELECT id FROM `%szones` WHERE groupname = '%s' AND map = '%s' AND name = '%s')", g_sTablePrefix, sEscapedGroupName, g_sCurrentMap, sEscapedZoneName);
		}
		else
		{
			Format(sQuery, sizeof(sQuery), "UPDATE `%szones` SET cluster_id = %s, name = '%s', pos_x = %f, pos_y = %f, pos_z = %f, min_x = %f, min_y = %f, min_z = %f, max_x = %f, max_y = %f, max_z = %f, rotation_x = %f, rotation_y = %f, rotation_z = %f, team = %d, color = %d WHERE id = %d", g_sTablePrefix, sClusterInsert, sEscapedZoneName, XYZ(zoneData[ZD_position]), XYZ(zoneData[ZD_mins]), XYZ(zoneData[ZD_maxs]), XYZ(zoneData[ZD_rotation]), zoneData[ZD_teamFilter], iColor, zoneData[ZD_databaseId]);
			
			Format(sZoneInsert, sizeof(sZoneInsert), "%d", zoneData[ZD_databaseId]);
		}
		hTransaction.AddQuery(sQuery);
		
		// Insert custom key values if there was something set.
		if (!zoneData[ZD_customKVChanged] || !zoneData[ZD_customKV])
			continue;
		
		// Have to remove all kv first
		// This is much easier than tracking which key got deleted.
		// TODO: Optimize to only update changed ones.
		Format(sQuery, sizeof(sQuery), "DELETE FROM `%scustom_zone_keyvalues` WHERE zone_id = %d", g_sTablePrefix, zoneData[ZD_databaseId]);
		hTransaction.AddQuery(sQuery);
		
		hTrieSnapshot = zoneData[ZD_customKV].Snapshot();
		iNumTrieKeys = hTrieSnapshot.Length;
		for (int k=0; k<iNumTrieKeys; k++)
		{
			hTrieSnapshot.GetKey(k, sKey, sizeof(sKey));
			zoneData[ZD_customKV].GetString(sKey, sValue, sizeof(sValue));
			g_hDatabase.Escape(sKey, sEscapedKey, sizeof(sEscapedKey));
			g_hDatabase.Escape(sValue, sEscapedValue, sizeof(sEscapedValue));
			Format(sQuery, sizeof(sQuery), "INSERT INTO `%scustom_zone_keyvalues` (zone_id, setting, val) VALUES (%s, '%s', '%s')", g_sTablePrefix, sZoneInsert, sEscapedKey, sEscapedValue);
			hTransaction.AddQuery(sQuery);
		}
		delete hTrieSnapshot;
	}
	
	// Delete all deleted clusters now.
	if (sClustersToDelete[0])
	{
		Format(sQuery, sizeof(sQuery), "DELETE FROM `%sclusters` WHERE id IN(%s)", g_sTablePrefix, sClustersToDelete);
		hTransaction.AddQuery(sQuery);
	}
	
	g_hDatabase.Execute(hTransaction, SQLTxn_InsertSuccess, SQLTxn_InsertZonesFailure);
}

public void SQLTxn_InsertSuccess(Database db, any data, int numQueries, Handle[] results, any[] queryData)
{
}

public void SQLTxn_InsertClusterFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("Error saving clusters on map (%d/%d). Error: %s", failIndex, numQueries, error);
}

public void SQLTxn_InsertZonesFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("Error saving zones on map (%d/%d). Error: %s", failIndex, numQueries, error);
}

/**
 * Zone trigger handling
 */
void SetupGroupZones(int group[ZoneGroup])
{
	int iSize = group[ZG_zones].Length;
	int zoneData[ZoneData];
	for(int i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		SetupZone(group, zoneData);
	}
}

bool SetupZone(int group[ZoneGroup], int zoneData[ZoneData])
{
	// Refuse to create a trigger for a soft-deleted zone.
	if(zoneData[ZD_deleted])
		return false;

	int iTrigger = CreateEntityByName("trigger_multiple");
	if(iTrigger == INVALID_ENT_REFERENCE)
		return false;
	
	char sTargetName[64];
	Format(sTargetName, sizeof(sTargetName), "mapzonelib_%d_%d", group[ZG_index], zoneData[ZD_index]);
	DispatchKeyValue(iTrigger, "targetname", sTargetName);
	
	DispatchKeyValue(iTrigger, "spawnflags", "1"); // triggers on clients (players) only
	DispatchKeyValue(iTrigger, "wait", "0");
	
	// Make sure any old trigger is gone.
	RemoveZoneTrigger(group, zoneData);
	
	float fRotation[3];
	Array_Copy(zoneData[ZD_rotation], fRotation, 3);
	bool bIsRotated = !Math_VectorsEqual(fRotation, view_as<float>({0.0,0.0,0.0}));
	
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
	int iEffects = GetEntProp(iTrigger, Prop_Send, "m_fEffects");
	iEffects |= 32;
	SetEntProp(iTrigger, Prop_Send, "m_fEffects", iEffects);

	HookSingleEntityOutput(iTrigger, "OnStartTouch", EntOut_OnTouchEvent);
	HookSingleEntityOutput(iTrigger, "OnTrigger", EntOut_OnTouchEvent);
	HookSingleEntityOutput(iTrigger, "OnEndTouch", EntOut_OnTouchEvent);
	
	return true;
}

void ApplyNewTriggerBounds(int zoneData[ZoneData])
{
	int iTrigger = EntRefToEntIndex(zoneData[ZD_triggerEntity]);
	if(iTrigger == INVALID_ENT_REFERENCE)
		return;
	
	float fPos[3], fAngles[3];
	Array_Copy(zoneData[ZD_position], fPos, 3);
	Array_Copy(zoneData[ZD_rotation], fAngles, 3);
	TeleportEntity(iTrigger, fPos, fAngles, NULL_VECTOR);

	float fMins[3], fMaxs[3];
	Array_Copy(zoneData[ZD_mins], fMins, 3);
	Array_Copy(zoneData[ZD_maxs], fMaxs, 3);

	// The server admin might want to have players being considered in a zone
	// based on where the center of their body is instead of the outer bounds
	// of the player model.
	if(g_hCVPlayerCenterCollision.BoolValue)
	{
		static float fReduction[3] = {16.0, 16.0, 36.0};
		for(int i=0;i<3;i++)
		{
			// Make sure the trigger bounds don't cross each other for really small triggers.
			if((fMins[i]+fReduction[i]) < fMaxs[i])
				fMins[i] += fReduction[i];

			if((fMaxs[i]-fReduction[i]) > fMins[i])
				fMaxs[i] -= fReduction[i];
		}
	}

	Entity_SetMinMaxSize(iTrigger, fMins, fMaxs);
	
	AcceptEntityInput(iTrigger, "Disable");
	AcceptEntityInput(iTrigger, "Enable");
}

bool ApplyTeamRestrictionFilter(int group[ZoneGroup], int zoneData[ZoneData])
{
	int iTrigger = EntRefToEntIndex(zoneData[ZD_triggerEntity]);
	if(iTrigger == INVALID_ENT_REFERENCE)
		return false;
	
	// See if that zone is restricted to one team.
	if(zoneData[ZD_teamFilter] >= 2 && zoneData[ZD_teamFilter] <= 3)
	{
		char sTargetName[64];
		Format(sTargetName, sizeof(sTargetName), "mapzone_filter_team%d", zoneData[ZD_teamFilter]);
		if(group[ZG_filterEntTeam][zoneData[ZD_teamFilter]-2] == INVALID_ENT_REFERENCE || EntRefToEntIndex(group[ZG_filterEntTeam][zoneData[ZD_teamFilter]-2]) == INVALID_ENT_REFERENCE)
		{
			int iFilter = CreateEntityByName("filter_activator_team");
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

int FindSmallestExistingEncapsulatingTrigger(int zoneData[ZoneData])
{
	// Already found a model. Just use it.
	if(zoneData[ZD_triggerModel][0] != 0)
		return;

	float vMins[3], vMaxs[3];
	float fLength, vDiag[3];
	GetEntPropVector(0, Prop_Data, "m_WorldMins", vMins);
	GetEntPropVector(0, Prop_Data, "m_WorldMaxs", vMaxs);
	
	SubtractVectors(vMins, vMaxs, vDiag);
	fLength = GetVectorLength(vDiag);
	
	//LogMessage("World mins [%f,%f,%f] maxs [%f,%f,%f] diag length %f", XYZ(vMins), XYZ(vMaxs), fLength);
	
	// The map itself would be always large enough - but often it's way too large!
	float fSmallestLength = fLength;
	GetCurrentMap(zoneData[ZD_triggerModel], sizeof(zoneData[ZD_triggerModel]));
	Format(zoneData[ZD_triggerModel], sizeof(zoneData[ZD_triggerModel]), "maps/%s.bsp", zoneData[ZD_triggerModel]);

	int iMaxEnts = GetEntityCount();
	char sModel[256], sClassname[256], sName[64];
	bool bLargeEnough;
	for(int i=MaxClients+1;i<iMaxEnts;i++)
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
		for(int v=0;v<3;v++)
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

void SetupAllGroupZones()
{
	int group[ZoneGroup];
	int iSize = g_hZoneGroups.Length;
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		SetupGroupZones(group);
	}
}

void RemoveZoneTrigger(int group[ZoneGroup], int zoneData[ZoneData])
{
	int iTrigger = EntRefToEntIndex(zoneData[ZD_triggerEntity]);
	if(iTrigger == INVALID_ENT_REFERENCE)
		return;
	
	// Fire leave callback for all touching clients.
	for(int i=1;i<=MaxClients;i++)
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
void ClearZonesInGroups()
{
	int group[ZoneGroup];
	int iSize = g_hZoneGroups.Length;
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		ClearZonesinGroup(group);
	}
}

void ClearZonesinGroup(int group[ZoneGroup])
{
	CloseCustomKVInZones(group);
	group[ZG_zones].Clear();
	
	CloseCustomKVInClusters(group);
	group[ZG_cluster].Clear();
}

void CloseCustomKVInZones(int group[ZoneGroup])
{
	int zoneData[ZoneData];
	int iSize = group[ZG_zones].Length;
	for(int i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		
		if (!zoneData[ZD_customKV])
			continue;
		
		delete zoneData[ZD_customKV];
	}
}

void CloseCustomKVInClusters(int group[ZoneGroup])
{
	int zoneCluster[ZoneCluster];
	int iSize = group[ZG_cluster].Length;
	for(int i=0;i<iSize;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		
		if (!zoneCluster[ZC_customKV])
			continue;
		
		delete zoneCluster[ZC_customKV];
	}
}

void GetGroupByIndex(int iIndex, int group[ZoneGroup])
{
	g_hZoneGroups.GetArray(iIndex, group[0], view_as<int>(ZoneGroup));
}

bool GetGroupByName(const char[] sName, int group[ZoneGroup])
{
	int iSize = g_hZoneGroups.Length;
	for(int i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		if(StrEqual(group[ZG_name], sName, false))
			return true;
	}
	return false;
}

void SaveGroup(int group[ZoneGroup])
{
	g_hZoneGroups.SetArray(group[ZG_index], group[0], view_as<int>(ZoneGroup));
}

void GetZoneByIndex(int iIndex, int group[ZoneGroup], int zoneData[ZoneData])
{
	group[ZG_zones].GetArray(iIndex, zoneData[0], view_as<int>(ZoneData));
}

bool GetZoneByName(const char[] sName, int group[ZoneGroup], int zoneData[ZoneData])
{
	int iSize = group[ZG_zones].Length;
	for(int i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		if(StrEqual(zoneData[ZD_name], sName, false))
			return true;
	}
	return false;
}

void SaveZone(int group[ZoneGroup], int zoneData[ZoneData])
{
	group[ZG_zones].SetArray(zoneData[ZD_index], zoneData[0], view_as<int>(ZoneData));
}

bool ZoneExistsWithName(int group[ZoneGroup], const char[] sZoneName)
{
	int zoneData[ZoneData];
	return GetZoneByName(sZoneName, group, zoneData);
}

void GetZoneClusterByIndex(int iIndex, int group[ZoneGroup], int zoneCluster[ZoneCluster])
{
	group[ZG_cluster].GetArray(iIndex, zoneCluster[0], view_as<int>(ZoneCluster));
}

bool GetZoneClusterByName(const char[] sName, int group[ZoneGroup], int zoneCluster[ZoneCluster])
{
	int iSize = group[ZG_cluster].Length;
	for(int i=0;i<iSize;i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		if(zoneCluster[ZC_deleted])
			continue;
		
		if(StrEqual(zoneCluster[ZC_name], sName, false))
			return true;
	}
	return false;
}

void SaveCluster(int group[ZoneGroup], int zoneCluster[ZoneCluster])
{
	group[ZG_cluster].SetArray(zoneCluster[ZC_index], zoneCluster[0], view_as<int>(ZoneCluster));
}

bool ClusterExistsWithName(int group[ZoneGroup], const char[] sClusterName)
{
	int zoneCluster[ZoneCluster];
	return GetZoneClusterByName(sClusterName, group, zoneCluster);
}

void RemoveClientFromAllZones(int client)
{
	int iNumGroups = g_hZoneGroups.Length;
	int iNumZones, group[ZoneGroup], zoneData[ZoneData];
	for(int i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		iNumZones = group[ZG_zones].Length;
		for(int z=0;z<iNumZones;z++)
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

void CallOnCreatedForAllInGroup(int group[ZoneGroup])
{
	// Inform other plugins that these clusters are there now.
	int iSize = group[ZG_cluster].Length;
	int zoneCluster[ZoneCluster];
	for (int i=0; i<iSize; i++)
	{
		GetZoneClusterByIndex(i, group, zoneCluster);
		if (zoneCluster[ZC_deleted])
			continue;
		
		CallOnClusterCreated(group, zoneCluster);
	}
	
	// And all these zones too.
	iSize = group[ZG_zones].Length;
	int zoneData[ZoneData];
	for (int i=0; i<iSize; i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if (zoneData[ZD_deleted])
			continue;
		
		CallOnZoneCreated(group, zoneData);
		
		if (zoneData[ZD_clusterIndex] == -1)
			continue;
		
		GetZoneClusterByIndex(zoneData[ZD_clusterIndex], group, zoneCluster);
		if (zoneCluster[ZC_deleted])
			continue;
		
		CallOnAddedToCluster(group, zoneData, zoneCluster, 0);
	}
}

// The creator defaults to 0 if the zone has been loaded from the config or database.
void CallOnZoneCreated(int group[ZoneGroup], int zoneData[ZoneData], int iCreator=0)
{
	Call_StartForward(g_hfwdOnCreatedForward);
	Call_PushString(group[ZG_name]);
	Call_PushString(zoneData[ZD_name]);
	Call_PushCell(MapZoneType_Zone);
	Call_PushCell(iCreator);
	Call_Finish();
}

// The creator defaults to 0 if the zone has been loaded from the config or database.
void CallOnClusterCreated(int group[ZoneGroup], int zoneCluster[ZoneCluster], int iCreator=0)
{
	Call_StartForward(g_hfwdOnCreatedForward);
	Call_PushString(group[ZG_name]);
	Call_PushString(zoneCluster[ZC_name]);
	Call_PushCell(MapZoneType_Cluster);
	Call_PushCell(iCreator);
	Call_Finish();
}

void CallOnZoneRemoved(int group[ZoneGroup], int zoneData[ZoneData], int iDeleter)
{
	Call_StartForward(g_hfwdOnRemovedForward);
	Call_PushString(group[ZG_name]);
	Call_PushString(zoneData[ZD_name]);
	Call_PushCell(MapZoneType_Zone);
	Call_PushCell(iDeleter);
	Call_Finish();
}

void CallOnClusterRemoved(int group[ZoneGroup], int zoneCluster[ZoneCluster], int iDeleter)
{
	Call_StartForward(g_hfwdOnRemovedForward);
	Call_PushString(group[ZG_name]);
	Call_PushString(zoneCluster[ZC_name]);
	Call_PushCell(MapZoneType_Cluster);
	Call_PushCell(iDeleter);
	Call_Finish();
}

void CallOnAddedToCluster(int group[ZoneGroup], int zoneData[ZoneData], int zoneCluster[ZoneCluster], int iAdmin)
{
	Call_StartForward(g_hfwdOnAddedToClusterForward);
	Call_PushString(group[ZG_name]);
	Call_PushString(zoneData[ZD_name]);
	Call_PushString(zoneCluster[ZC_name]);
	Call_PushCell(iAdmin);
	Call_Finish();
}

void CallOnRemovedFromCluster(int group[ZoneGroup], int zoneData[ZoneData], int zoneCluster[ZoneCluster], int iAdmin)
{
	Call_StartForward(g_hfwdOnRemovedFromClusterForward);
	Call_PushString(group[ZG_name]);
	Call_PushString(zoneData[ZD_name]);
	Call_PushString(zoneCluster[ZC_name]);
	Call_PushCell(iAdmin);
	Call_Finish();
}

/**
 * Zone adding
 */
bool IsClientEditingZonePosition(int client)
{
	return g_ClientMenuState[client][CMS_addZone] || g_ClientMenuState[client][CMS_editPosition] || g_ClientMenuState[client][CMS_editCenter];
}

void HandleZonePositionSetting(int client, const float fOrigin[3])
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
				// Don't clear the menu state when we interrupt the point edit menu.
				g_ClientMenuState[client][CMS_redrawPointMenu] = true;
				
				int group[ZoneGroup];
				GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
				
				// See if we have a valid name already given.
				bool bPresetName = g_ClientMenuState[client][CMS_presetZoneName][0] != 0;
				
				// There is a name already given for this zone. use it.
				if (bPresetName
				&& !ZoneExistsWithName(group, g_ClientMenuState[client][CMS_presetZoneName])
				&& !ClusterExistsWithName(group, g_ClientMenuState[client][CMS_presetZoneName]))
				{
					SaveNewZone(client, g_ClientMenuState[client][CMS_presetZoneName]);
				}
				else
				{
					// Inform admin that the preset name failed.
					if (bPresetName)
					{
						PrintToChat(client, "Map Zones > A zone with the name \"%s\" in group \"%s\" already exists.", g_ClientMenuState[client][CMS_presetZoneName], group[ZG_name]);
					}
					
					g_ClientMenuState[client][CMS_editState] = ZES_name;
					
					DisplayZoneAddFinalizationMenu(client);
					PrintToChat(client, "Map Zones > Please type a name for this zone in chat. Type \"!abort\" to abort.");
				}
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

bool GetClientZoneAimPosition(int client, float fTarget[3], float fUnsnappedTarget[3])
{
	float fClientPosition[3], fClientAngles[3];
	GetClientEyePosition(client, fClientPosition);
	
	// When a player is currently holding rightclick while editing a zone point position,
	// he's trying to adjust the maximal distance of the laserpointer point which specifies the target position.
	// Don't change the pointer position while moving the mouse up and down to change the distance.
	bool bIsAdjustingAimLimit = g_ClientMenuState[client][CMS_previewMode] == ZPM_aim && (g_iClientButtons[client] & IN_ATTACK2 == IN_ATTACK2) && IsClientEditingZonePosition(client);
	if (bIsAdjustingAimLimit)
	{
		fClientAngles = g_fAimCapTempAngles[client];
	}
	else
	{
		GetClientEyeAngles(client, fClientAngles);
	}
	
	// See what the client is aiming at.
	bool bDidHit;
	TR_TraceRayFilter(fClientPosition, fClientAngles, MASK_SOLID, RayType_Infinite, RayFilter_DontHitSelf, client);
	bDidHit = TR_DidHit();
	
	// See if we need to cap it.
	float fAimDirection[3], fTargetNormal[3];
	// We did hit something over there.
	if (bDidHit)
	{
		TR_GetEndPosition(fUnsnappedTarget);
		
		TR_GetPlaneNormal(INVALID_HANDLE, fTargetNormal);
		NormalizeVector(fTargetNormal, fTargetNormal);
		
		// Make sure the normal is facing the player.
		float fDirectionToPlayer[3];
		MakeVectorFromPoints(fUnsnappedTarget, fClientPosition, fDirectionToPlayer);
		NormalizeVector(fDirectionToPlayer, fDirectionToPlayer);
		if(GetVectorDotProduct(fDirectionToPlayer, fTargetNormal) < 0)
			NegateVector(fTargetNormal);
		
		// Snap the point to the grid, if the user wants it.
		SnapToGrid(client, fUnsnappedTarget, fTarget, fTargetNormal);
		
		MakeVectorFromPoints(fClientPosition, fTarget, fAimDirection);
		
		// Player is aiming at something that's nearer than the current maximal distance?
		float fDistance = GetVectorLength(fAimDirection);
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
bool GetClientFeetPosition(int client, float fFeetPosition[3], float fGroundNormal[3])
{
	float fOrigin[3];
	GetClientAbsOrigin(client, fOrigin);
	fFeetPosition = fOrigin;
	
	// Trace directly downwards
	fOrigin[2] += 16.0;
	TR_TraceRayFilter(fOrigin, view_as<float>({90.0,0.0,0.0}), MASK_PLAYERSOLID, RayType_Infinite, RayFilter_DontHitPlayers);
	if (TR_DidHit())
	{
		TR_GetEndPosition(fOrigin);
		TR_GetPlaneNormal(INVALID_HANDLE, fGroundNormal);
		NormalizeVector(fGroundNormal, fGroundNormal);
		
		// Make sure the normal is facing the player.
		float fDirectionToPlayer[3];
		MakeVectorFromPoints(fOrigin, fFeetPosition, fDirectionToPlayer);
		NormalizeVector(fDirectionToPlayer, fDirectionToPlayer);
		if(GetVectorDotProduct(fDirectionToPlayer, fGroundNormal) < 0)
			NegateVector(fGroundNormal);
		
		return true;
	}
	return false;
}

void SnapToGrid(int client, float fPoint[3], float fSnappedPoint[3], float fTargetNormal[3])
{
	// User has this disabled.
	if(!g_ClientMenuState[client][CMS_snapToGrid])
	{
		fSnappedPoint = fPoint;
		return;
	}
		
	float fStepsize = g_fStepsizes[g_ClientMenuState[client][CMS_stepSizeIndex]];
	for(int i=0; i<3; i++)
	{
		fSnappedPoint[i] = RoundToNearest(fPoint[i] / fStepsize) * fStepsize;
	}
	
	// Snap to walls!
	// See if the grid snapped behind the target point.
	if (!Math_VectorsEqual(fTargetNormal, view_as<float>({0.0,0.0,0.0})))
	{
		float fSnappedDirection[3];
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
		
		bool bChanged;
		do
		{
			bChanged = false;
			// See if we're still behind some other wall after moving the point toward the normal again.
			float fAngles[3];
			MakeVectorFromPoints(fPoint, fSnappedPoint, fSnappedDirection);
			NormalizeVector(fSnappedDirection, fSnappedDirection);
			GetVectorAngles(fSnappedDirection, fAngles);
			
			TR_TraceRayFilter(fPoint, fAngles, MASK_PLAYERSOLID, RayType_Infinite, RayFilter_DontHitPlayers);
			if (!TR_DidHit())
				return;
			
			float fOtherWall[3], fOtherWallDirection[3];
			TR_GetEndPosition(fOtherWall);
			MakeVectorFromPoints(fOtherWall, fSnappedPoint, fOtherWallDirection);
			NormalizeVector(fOtherWallDirection, fOtherWallDirection);
			
			TR_GetPlaneNormal(INVALID_HANDLE, fTargetNormal);
			NormalizeVector(fTargetNormal, fTargetNormal);
			
			// Make sure the normal is facing the player.
			float fDirectionToPlayer[3];
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

bool Math_GetLinePlaneIntersection(float fLinePoint[3], float fLineDirection[3], float fPlanePoint[3], float fPlaneNormal[3], float fCollisionPoint[3])
{
	float fCos = GetVectorDotProduct(fLineDirection, fPlaneNormal);
	// Line is parallel to the plane. No single intersection point.
	if (fCos == 0.0)
		return false;
	
	float fTowardsPlane[3];
	SubtractVectors(fPlanePoint, fLinePoint, fTowardsPlane);
	
	float fDistance = GetVectorDotProduct(fTowardsPlane, fPlaneNormal) / fCos;
	float fMoveOnLine[3];
	fMoveOnLine = fLineDirection;
	ScaleVector(fMoveOnLine, fDistance);
	AddVectors(fLinePoint, fMoveOnLine, fCollisionPoint);
	return true;
}

// Handle the default height of a zone when it's too flat.
void HandleZoneDefaultHeight(float &fFirstPointZ, float &fSecondPointZ)
{
	float fDefaultHeight = g_hCVDefaultHeight.FloatValue;
	if (fDefaultHeight == 0.0)
		return;
	
	float fMinHeight = g_hCVMinHeight.FloatValue;
	float fZoneHeight = FloatAbs(fFirstPointZ - fSecondPointZ);
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

void StartZoneAdding(int client)
{
	g_ClientMenuState[client][CMS_addZone] = true;
	g_ClientMenuState[client][CMS_editState] = ZES_first;
	DisplayZonePointEditMenu(client);
	PrintToChat(client, "Map Zones > Click on the two points or push \"e\" to set them at your feet, which will specify the two diagonal opposite corners of the zone.");
}

void ResetZoneAddingState(int client)
{
	g_ClientMenuState[client][CMS_addZone] = false;
	g_ClientMenuState[client][CMS_editState] = ZES_first;
	g_ClientMenuState[client][CMS_presetZoneName][0] = 0;
	Array_Fill(g_ClientMenuState[client][CMS_first], 3, 0.0);
	Array_Fill(g_ClientMenuState[client][CMS_second], 3, 0.0);
	ClearHandle(g_hShowZoneWhileEditTimer[client]);
}

void SaveNewZone(int client, const char[] sName)
{
	if(!g_ClientMenuState[client][CMS_addZone])
		return;

	int group[ZoneGroup], zoneCluster[ZoneCluster];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	if(g_ClientMenuState[client][CMS_cluster] != -1)
		GetZoneClusterByIndex(g_ClientMenuState[client][CMS_cluster], group, zoneCluster);
	
	int zoneData[ZoneData];
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
	
	zoneData[ZD_index] = group[ZG_zones].Length;
	group[ZG_zones].PushArray(zoneData[0], view_as<int>(ZoneData));
	
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
	
	// Inform other plugins that this zone is here now.
	CallOnZoneCreated(group, zoneData, client);
	
	// Tell if this zone was added to a cluster right away.
	if (zoneData[ZD_clusterIndex] != -1)
		CallOnAddedToCluster(group, zoneData, zoneCluster, client);
	
	// Edit the new zone right away.
	g_ClientMenuState[client][CMS_zone] = zoneData[ZD_index];
	
	// If we just pasted this zone, we want to edit the center position right away!
	if(g_ClientMenuState[client][CMS_editCenter])
		DisplayZonePointEditMenu(client);
	else
		DisplayZoneEditMenu(client);
}

void SaveChangedZoneCoordinates(int client, int zoneData[ZoneData])
{
	float fMins[3], fMaxs[3], fPosition[3], fAngles[3];
	Array_Copy(g_ClientMenuState[client][CMS_rotation], fAngles, 3);
	Array_Copy(g_ClientMenuState[client][CMS_first], fMins, 3);
	Array_Copy(g_ClientMenuState[client][CMS_second], fMaxs, 3);
	
	float fOldMins[3];
	// Apply the rotation so we find the right middle, if there is rotation already.
	if(!Math_VectorsEqual(fAngles, view_as<float>({0.0,0.0,0.0})))
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
	for(int i=0;i<3;i++)
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
	if(!Math_VectorsEqual(fAngles, view_as<float>({0.0,0.0,0.0})))
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

void GetFreeAutoZoneName(int group[ZoneGroup], char[] sBuffer, int maxlen)
{
	int iIndex = 1;
	do
	{
		Format(sBuffer, maxlen, "Zone %d", iIndex++);
	} while(ZoneExistsWithName(group, sBuffer));
}

void AddNewCluster(int group[ZoneGroup], const char[] sClusterName, int zoneCluster[ZoneCluster])
{
	strcopy(zoneCluster[ZC_name], MAX_ZONE_NAME, sClusterName);
	// Don't use a seperate color for this cluster by default.
	zoneCluster[ZC_color][0] = -1;
	zoneCluster[ZC_index] = group[ZG_cluster].Length;
	group[ZG_cluster].PushArray(zoneCluster[0], view_as<int>(ZoneCluster));
}

/**
 * Clipboard helpers
 */
void ClearClientClipboard(int client)
{
	Array_Fill(g_Clipboard[client][CB_mins], 3, 0.0);
	Array_Fill(g_Clipboard[client][CB_maxs], 3, 0.0);
	Array_Fill(g_Clipboard[client][CB_position], 3, 0.0);
	Array_Fill(g_Clipboard[client][CB_rotation], 3, 0.0);
	g_Clipboard[client][CB_name][0] = '\0';
}

void SaveToClipboard(int client, int zoneData[ZoneData])
{
	Array_Copy(zoneData[ZD_mins], g_Clipboard[client][CB_mins], 3);
	Array_Copy(zoneData[ZD_maxs], g_Clipboard[client][CB_maxs], 3);
	Array_Copy(zoneData[ZD_position], g_Clipboard[client][CB_position], 3);
	Array_Copy(zoneData[ZD_rotation], g_Clipboard[client][CB_rotation], 3);
	strcopy(g_Clipboard[client][CB_name], MAX_ZONE_NAME, zoneData[ZD_name]);
}

void PasteFromClipboard(int client)
{
	// We want to edit the center position directly afterwards
	g_ClientMenuState[client][CMS_editCenter] = true;
	// But first we have to add the zone to the current group and give it a new name.
	g_ClientMenuState[client][CMS_addZone] = true;
	g_ClientMenuState[client][CMS_editState] = ZES_name;
	
	// Copy the details to the client state.
	for(int i=0;i<3;i++)
	{
		g_ClientMenuState[client][CMS_first][i] = g_Clipboard[client][CB_position][i] + g_Clipboard[client][CB_mins][i];
		g_ClientMenuState[client][CMS_second][i] = g_Clipboard[client][CB_position][i] + g_Clipboard[client][CB_maxs][i];
		g_ClientMenuState[client][CMS_rotation][i] = g_Clipboard[client][CB_rotation][i];
		g_ClientMenuState[client][CMS_center][i] = g_Clipboard[client][CB_position][i];
	}
	
	PrintToChat(client, "Map Zones > Please type a new name for this new copy of zone \"%s\" in chat. Type \"!abort\" to abort.", g_Clipboard[client][CB_name]);
	DisplayZoneAddFinalizationMenu(client);
}

bool HasZoneInClipboard(int client)
{
	return g_Clipboard[client][CB_name][0] != '\0';
}

/**
 * Generic helpers
 */
bool ExtractIndicesFromString(const char[] sTargetName, int &iGroupIndex, int &iZoneIndex)
{
	char sBuffer[64];
	strcopy(sBuffer, sizeof(sBuffer), sTargetName);

	// Has to start with "mapzonelib_"
	if(StrContains(sBuffer, "mapzonelib_") != 0)
		return false;
	
	ReplaceString(sBuffer, sizeof(sBuffer), "mapzonelib_", "");
	
	int iLen = strlen(sBuffer);
	
	// Extract the group and zone indicies from the targetname.
	int iUnderscorePos = FindCharInString(sBuffer, '_');
	
	// Zone index missing?
	if(iUnderscorePos+1 >= iLen)
		return false;
	
	iZoneIndex = StringToInt(sBuffer[iUnderscorePos+1]);
	sBuffer[iUnderscorePos] = 0;
	iGroupIndex = StringToInt(sBuffer);
	return true;
}

void Vector_GetMiddleBetweenPoints(const float vec1[3], const float vec2[3], float result[3])
{
	float mid[3];
	MakeVectorFromPoints(vec1, vec2, mid);
	mid[0] = mid[0] / 2.0;
	mid[1] = mid[1] / 2.0;
	mid[2] = mid[2] / 2.0;
	AddVectors(vec1, mid, result);
}

public bool RayFilter_DontHitSelf(int entity, int contentsMask, any data)
{
	return entity != data;
}

public bool RayFilter_DontHitPlayers(int entity, int contentsMask, any data)
{
	return entity < 1 && entity > MaxClients;
}
