#pragma semicolon 1
#include <sourcemod>
#include <smlib>

#define PLUGIN_VERSION "1.0"

#define MAX_ZONE_GROUP_NAME 64
#define MAX_ZONE_NAME 64

enum ZoneData {
	ZD_index,
	ZD_triggerEntity,
	Float:ZD_position[3],
	Float:ZD_mins[3],
	Float:ZD_maxs[3],
	Float:ZD_rotation[3],
	bool:ZD_deleted, // We can't directly delete zones, because we use the array index as identifier. Deleting would mean an array shiftup.
	String:ZD_name[MAX_ZONE_NAME]
}

enum ZoneGroup {
	ZG_index,
	Handle:ZG_zones,
	bool:ZG_showZones,
	String:ZG_name[MAX_ZONE_GROUP_NAME]
}

enum ZoneEditState {
	ZES_first,
	ZES_second,
	ZES_name
}

enum ClientMenuState {
	CMS_group,
	CMS_zone,
	bool:CMS_rename,
	bool:CMS_addZone,
	bool:CMS_editRotation,
	bool:CMS_editPosition,
	ZoneEditState:CMS_editState,
	Float:CMS_first[3],
	Float:CMS_second[3],
	Float:CMS_rotation[3]
}

new Handle:g_hfwdOnEnterForward;
new Handle:g_hfwdOnLeaveForward;

new Handle:g_hShowZonesTimer;
new g_iLaserMaterial = -1;
new g_iHaloMaterial = -1;
new g_iGlowSprite = -1;

new Handle:g_hZoneGroups;

new g_ClientMenuState[MAXPLAYERS+1][ClientMenuState];

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
	//CreateNative("MapZone_SetMenuBackAction", Native_SetMenuBackAction);
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
	
	HookEvent("round_start", Event_OnRoundStart);
	HookEvent("bullet_impact", Event_OnBulletImpact);
	
	// Clear menu states
	for(new i=1;i<=MaxClients;i++)
		OnClientDisconnect(i);
}

public OnPluginEnd()
{
	SaveAllZoneGroupsToFile();
	// TODO: Kill all created trigger_multiple.
}

/**
 * Core forward callbacks
 */
public OnMapStart()
{
	PrecacheModel("models/error.mdl", true);

	g_iLaserMaterial = PrecacheModel("materials/sprites/laser.vmt", true);
	g_iHaloMaterial = PrecacheModel("materials/sprites/halo01.vmt", true);
	g_iGlowSprite = PrecacheModel("sprites/blueglow2.vmt", true);
	
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
	g_ClientMenuState[client][CMS_zone] = -1;
	g_ClientMenuState[client][CMS_rename] = false;
	g_ClientMenuState[client][CMS_editRotation] = false;
	g_ClientMenuState[client][CMS_editPosition] = false;
	ResetZoneAddingState(client);
}

public OnClientSayCommand_Post(client, const String:command[], const String:sArgs[])
{
	if(g_ClientMenuState[client][CMS_rename])
	{
		g_ClientMenuState[client][CMS_rename] = false;
	
		new group[ZoneGroup], zoneData[ZoneData];
		GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
		
		if(!StrContains(sArgs, "!abort"))
		{
			PrintToChat(client, "Map Zones > Renaming of zone \"%s\" stopped.", zoneData[ZD_name]);
			DisplayZoneEditMenu(client);
			return;
		}
		
		// Make sure the name is unique in this group.
		if(ZoneExistsWithName(group, sArgs))
		{
			PrintToChat(client, "Map Zones > There is a zone called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
			return;
		}
		
		strcopy(zoneData[ZD_name], MAX_ZONE_NAME, sArgs);
		SaveZone(group, zoneData);
		
		PrintToChat(client, "Map Zones > Zone \"%s\" renamed to \"%s\".", zoneData[ZD_name], sArgs);
		DisplayZoneEditMenu(client);
	}
	else if(g_ClientMenuState[client][CMS_addZone] && g_ClientMenuState[client][CMS_editState] == ZES_name)
	{
		new group[ZoneGroup];
		GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
		
		if(!StrContains(sArgs, "!abort"))
		{
			ResetZoneAddingState(client);
			
			PrintToChat(client, "Map Zones > Aborted adding of new zone.");
			DisplayGroupRootMenu(client, group);
			return;
		}
		
		if(ZoneExistsWithName(group, sArgs))
		{
			PrintToChat(client, "Map Zones > There is a zone called %s in the group \"%s\" already. Try a different name.", sArgs, group[ZG_name]);
			return;
		}
		
		SaveNewZone(client, sArgs);
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	static s_buttons[MAXPLAYERS+1];
	
	// Started pressing +use
	// See if he wants to set a zone's position.
	if(buttons & IN_USE && !(s_buttons[client] & IN_USE))
	{
		new Float:fOrigin[3];
		GetClientAbsOrigin(client, fOrigin);
		
		HandleZonePositionSetting(client, fOrigin);
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
		else if(s_buttons[client] & IN_USE)
			TriggerTimer(g_hShowZonesTimer, true);
	}
	
	s_buttons[client] = buttons;
	return Plugin_Continue;
}

/**
 * Event callbacks
 */
public Event_OnRoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	SetupAllGroupZones();
}

public Action:Event_OnBulletImpact(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new Float:x = GetEventFloat(event, "x");
	new Float:y = GetEventFloat(event, "y");
	new Float:z = GetEventFloat(event, "z");
	
	new Float:fOrigin[3];
	fOrigin[0] = x;
	fOrigin[1] = y;
	fOrigin[2] = z;
	
	HandleZonePositionSetting(client, fOrigin);
	
	return Plugin_Continue;
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
	strcopy(group[ZG_name][0], MAX_ZONE_GROUP_NAME, sName);
	group[ZG_zones] = CreateArray(_:ZoneData);
	group[ZG_showZones] = false;
	
	// Load the zone details
	LoadZoneGroup(group);
	
	group[ZG_index] = GetArraySize(g_hZoneGroups);
	PushArrayArray(g_hZoneGroups, group[0], _:ZoneGroup);
}

// native bool:MapZone_ShowMenu(client, const String:group[]);
public Native_ShowMenu(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);

	new String:sName[MAX_ZONE_GROUP_NAME];
	GetNativeString(2, sName, sizeof(sName));
	
	new group[ZoneGroup];
	if(!GetGroupByName(sName, group))
		return false;
	
	DisplayGroupRootMenu(client, group);
	return true;
}

/**
 * Entity output handler
 */
public EntOut_OnTouchEvent(const String:output[], caller, activator, Float:delay)
{
	// Ignore dead players
	if(activator < 1 || activator > MaxClients || !IsPlayerAlive(activator))
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
	
	if(StrEqual(output, "OnStartTouch"))
		Call_StartForward(g_hfwdOnEnterForward);
	else
		Call_StartForward(g_hfwdOnLeaveForward);
	Call_PushCell(activator);
	Call_PushString(group[ZG_name]);
	Call_PushString(zoneData[ZD_name]);
	Call_Finish();
}

/**
 * Timer callbacks
 */
public Action:Timer_ShowZones(Handle:timer)
{
	new iNumGroups = GetArraySize(g_hZoneGroups);
	new group[ZoneGroup], zoneData[ZoneData], iNumZones;
	new Float:fPos[3], Float:fMins[3], Float:fMaxs[3], Float:fAngles[3];
	for(new i=0;i<iNumGroups;i++)
	{
		GetGroupByIndex(i, group);
		
		if(!group[ZG_showZones])
			continue;
		
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
			
			Effect_DrawBeamBoxRotatableToAll(fPos, fMins, fMaxs, fAngles, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 5.0, 5.0, 2, 1.0, {255,0,0,255}, 0);
		}
	}
	
	new Float:vFirstPoint[3], Float: vSecondPoint[3];
	for(new i=1;i<=MaxClients;i++)
	{
		if(g_ClientMenuState[i][CMS_addZone] && g_ClientMenuState[i][CMS_editState] == ZES_name)
		{
			for(new a=0;a<3;a++)
			{
				vFirstPoint[a] = g_ClientMenuState[i][CMS_first][a];
				vSecondPoint[a] = g_ClientMenuState[i][CMS_second][a];
			}
			
			Effect_DrawBeamBoxToClient(i, vFirstPoint, vSecondPoint, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 2.0, 5.0, 5.0, 2, 1.0, {0,0,255,255}, 0);
		}
		
		if(g_ClientMenuState[i][CMS_editPosition]
		|| g_ClientMenuState[i][CMS_editRotation])
		{
			GetGroupByIndex(g_ClientMenuState[i][CMS_group], group);
			GetZoneByIndex(g_ClientMenuState[i][CMS_zone], group, zoneData);
			
			Array_Copy(zoneData[ZD_position], fPos, 3);
			Array_Copy(g_ClientMenuState[i][CMS_rotation], fAngles, 3);
			
			// Get the bounds and only have the rotation changable.
			if(g_ClientMenuState[i][CMS_editRotation])
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
	
	g_ClientMenuState[client][CMS_editRotation] = false;

	new Handle:hMenu = CreateMenu(Menu_HandleGroupRoot);
	SetMenuTitle(hMenu, "Manage zones for \"%s\"", group[ZG_name]);
	SetMenuExitButton(hMenu, true);
	
	new String:sBuffer[64];
	Format(sBuffer, sizeof(sBuffer), "Show Zones: %T", (group[ZG_showZones]?"Yes":"No"), client);
	AddMenuItem(hMenu, "showzones", sBuffer);
	AddMenuItem(hMenu, "add", "Add new zone");
	AddMenuItem(hMenu, "", "", ITEMDRAW_SPACER|ITEMDRAW_DISABLED);
	
	new iNumZones = GetArraySize(group[ZG_zones]);
	if(iNumZones > 0)
	{
		AddMenuItem(hMenu, "", "Zones:", ITEMDRAW_DISABLED);
		new zoneData[ZoneData];
		for(new i=0;i<iNumZones;i++)
		{
			GetZoneByIndex(i, group, zoneData);
			// Ignore zones marked as deleted.
			if(zoneData[ZD_deleted])
				continue;
			
			IntToString(i, sBuffer, sizeof(sBuffer));
			AddMenuItem(hMenu, sBuffer, zoneData[ZD_name]);
		}
	}
	
	g_ClientMenuState[client][CMS_group] = group[ZG_index];
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
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
		if(StrEqual(sInfo, "showzones"))
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
			return;
		}
		else if(StrEqual(sInfo, "add"))
		{
			g_ClientMenuState[param1][CMS_addZone] = true;
			g_ClientMenuState[param1][CMS_editState] = ZES_first;
			PrintToChat(param1, "Map Zones > Shoot at the two points or push \"e\" to set them at your feet, which will specify the two diagonal opposite corners of the zone.");
			return;
		}
		
		new iZoneIndex = StringToInt(sInfo);
		g_ClientMenuState[param1][CMS_zone] = iZoneIndex;
		DisplayZoneEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_group] = -1;
	}
}

DisplayZoneEditMenu(client)
{
	new group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);

	if(zoneData[ZD_deleted])
	{
		DisplayGroupRootMenu(client, group);
		return;
	}
	
	new Handle:hMenu = CreateMenu(Menu_HandleZoneEdit);
	SetMenuExitBackButton(hMenu, true);
	SetMenuTitle(hMenu, "Manage zone \"%s\" in group \"%s\"", zoneData[ZD_name], group[ZG_name]);
	
	AddMenuItem(hMenu, "teleport", "Teleport to");
	AddMenuItem(hMenu, "position1", "Change first corner");
	AddMenuItem(hMenu, "position2", "Change second corner");
	AddMenuItem(hMenu, "rotation", "Change rotation");
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
		else if(!StrContains(sInfo, "position"))
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
			
			DisplayPositionEditMenu(param1);
		}
		else if(StrEqual(sInfo, "rotation"))
		{
			// Copy current rotation from zoneData to clientstate.
			Array_Copy(zoneData[ZD_rotation], g_ClientMenuState[param1][CMS_rotation], 3);
			g_ClientMenuState[param1][CMS_editRotation] = true;
			// Show box now
			TriggerTimer(g_hShowZonesTimer, true);
			DisplayZoneRotationMenu(param1);
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
			
			SendPanelToClient(hPanel, param1, Panel_HandleConfirmDelete, MENU_TIME_FOREVER);
			CloseHandle(hPanel);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_zone] = -1;
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

public Panel_HandleConfirmDelete(Handle:menu, MenuAction:action, param1, param2)
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
			DisplayGroupRootMenu(param1, group);
		}
		else
		{
			DisplayZoneEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_group] = -1;
		g_ClientMenuState[param1][CMS_zone] = -1;
	}
}

DisplayPositionEditMenu(client)
{
	new group[ZoneGroup], zoneData[ZoneData];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	GetZoneByIndex(g_ClientMenuState[client][CMS_zone], group, zoneData);
	
	new Handle:hMenu = CreateMenu(Menu_HandlePositionEdit);
	SetMenuTitle(hMenu, "Edit zone \"%s\" position %d\nShoot at the point or push \"e\" to set it at your feet.", zoneData[ZD_name], _:g_ClientMenuState[client][CMS_editState]+1);
	SetMenuExitBackButton(hMenu, true);

	AddMenuItem(hMenu, "save", "Save changes");
	
	AddMenuItem(hMenu, "ax", "Add to X axis");
	AddMenuItem(hMenu, "sx", "Subtract from X axis");
	AddMenuItem(hMenu, "ay", "Add to Y axis");
	AddMenuItem(hMenu, "sy", "Subtract from Y axis");
	AddMenuItem(hMenu, "az", "Add to Z axis");
	AddMenuItem(hMenu, "sz", "Subtract from Z axis");
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

public Menu_HandlePositionEdit(Handle:menu, MenuAction:action, param1, param2)
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
			SaveChangedZoneCoordinates(param1, zoneData);
			Array_Copy(g_ClientMenuState[param1][CMS_rotation], zoneData[ZD_rotation], 3);
			SaveZone(group, zoneData);
			SetupZone(group, zoneData);
			g_ClientMenuState[param1][CMS_editPosition] = false;
			g_ClientMenuState[param1][CMS_editState] = ZES_first;
			ResetZoneAddingState(param1);
			DisplayZoneEditMenu(param1);
			TriggerTimer(g_hShowZonesTimer, true);
			return;
		}
		
		// Add to x
		new Float:fValue = 5.0;
		if(sInfo[0] == 's')
			fValue *= -1;
		
		new iAxis = sInfo[1] - 'x';
		
		if(g_ClientMenuState[param1][CMS_editState] == ZES_first)
			g_ClientMenuState[param1][CMS_first][iAxis] += fValue;
		else
			g_ClientMenuState[param1][CMS_second][iAxis] += fValue;
		
		TriggerTimer(g_hShowZonesTimer, true);
		DisplayPositionEditMenu(param1);
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_editPosition] = false;
		g_ClientMenuState[param1][CMS_editState] = ZES_first;
		ResetZoneAddingState(param1);
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayZoneEditMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_zone] = -1;
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
			DisplayZoneEditMenu(param1);
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
			DisplayZoneEditMenu(param1);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		g_ClientMenuState[param1][CMS_editRotation] = false;
		Array_Fill(g_ClientMenuState[param1][CMS_rotation], 3, 0.0);
		if(param2 == MenuCancel_ExitBack)
		{
			DisplayZoneEditMenu(param1);
		}
		else
		{
			g_ClientMenuState[param1][CMS_zone] = -1;
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
	SetMenuTitle(hMenu, "Save new zone in group \"%s\"?", group[ZG_name]);
	SetMenuExitBackButton(hMenu, true);
	
	AddMenuItem(hMenu, "", "Type zone name in chat to save it. (\"!abort\" to abort)", ITEMDRAW_DISABLED);
	
	new String:sBuffer[128];
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
			DisplayGroupRootMenu(param1, group);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		ResetZoneAddingState(param1);
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
	
	if(!FileToKeyValues(hKV, sPath))
		return false;
	
	if(!KvGotoFirstSubKey(hKV))
		return false;
	
	new Float:vBuf[3], String:sZoneName[MAX_ZONE_NAME];
	do {
		new zoneData[ZoneData];
		KvGetVector(hKV, "pos", vBuf);
		Array_Copy(vBuf, zoneData[ZD_position], 3);
		
		KvGetVector(hKV, "mins", vBuf);
		Array_Copy(vBuf, zoneData[ZD_mins], 3);
		
		KvGetVector(hKV, "maxs", vBuf);
		Array_Copy(vBuf, zoneData[ZD_maxs], 3);
		
		KvGetVector(hKV, "rotation", vBuf);
		Array_Copy(vBuf, zoneData[ZD_rotation], 3);
		
		KvGetString(hKV, "name", sZoneName, sizeof(sZoneName), "unnamed");
		strcopy(zoneData[ZD_name][0], MAX_ZONE_NAME, sZoneName);
		
		zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
		zoneData[ZD_index] = GetArraySize(group[ZG_zones]);
		PushArrayArray(group[ZG_zones], zoneData[0], _:ZoneData);
		
	} while(KvGotoNextKey(hKV));
	
	CloseHandle(hKV);
	return true;
}

bool:SaveZoneGroupToFile(group[ZoneGroup])
{
	decl String:sPath[PLATFORM_MAX_PATH], String:sMap[128];
	GetCurrentMap(sMap, sizeof(sMap));
	
	// Have mercy and even create the root config file directory.
	BuildPath(Path_SM, sPath, sizeof(sPath),  "configs/mapzonelib");
	if(!DirExists(sPath))
	{
		if(!CreateDirectory(sPath, 0775))
			return false;
	}
	
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/mapzonelib/%s", group[ZG_name]);
	if(!DirExists(sPath))
	{
		if(!CreateDirectory(sPath, 0775))
			return false;
	}
	
	new Handle:hKV = CreateKeyValues("MapZoneGroup");
	if(!hKV)
		return false;
	
	// Add all zones of this group to the keyvalues file.
	new String:sIndex[16], zoneData[ZoneData], Float:vBuf[3];
	new iSize = GetArraySize(group[ZG_zones]);
	new bool:bZonesAdded;
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(zoneData[ZD_deleted])
			continue;
		
		bZonesAdded = true;
		
		IntToString(i, sIndex, sizeof(sIndex));
		KvJumpToKey(hKV, sIndex, true);
		
		Array_Copy(zoneData[ZD_position], vBuf, 3);
		KvSetVector(hKV, "pos", vBuf);
		Array_Copy(zoneData[ZD_mins], vBuf, 3);
		KvSetVector(hKV, "mins", vBuf);
		Array_Copy(zoneData[ZD_maxs], vBuf, 3);
		KvSetVector(hKV, "maxs", vBuf);
		Array_Copy(zoneData[ZD_rotation], vBuf, 3);
		KvSetVector(hKV, "rotation", vBuf);
		KvSetString(hKV, "name", zoneData[ZD_name]);
		
		KvGoBack(hKV);
	}
	
	KvRewind(hKV);
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/mapzonelib/%s/%s.zones", group[ZG_name], sMap);
	// Only add zones, if there are any for this map.
	if(bZonesAdded)
	{
		KeyValuesToFile(hKV, sPath);
	}
	else
	{
		// Remove the zone config otherwise, so we don't keep empty files around.
		DeleteFile(sPath);
	}
	CloseHandle(hKV);
	
	return true;
}

SaveAllZoneGroupsToFile()
{
	new group[ZoneGroup];
	new iSize = GetArraySize(g_hZoneGroups);
	for(new i=0;i<iSize;i++)
	{
		GetGroupByIndex(i, group);
		SaveZoneGroupToFile(group);
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
	
	zoneData[ZD_triggerEntity] = EntIndexToEntRef(iTrigger);
	SaveZone(group, zoneData);
	
	DispatchSpawn(iTrigger);
	ActivateEntity(iTrigger);
	
	decl String:sModel[PLATFORM_MAX_PATH];
	GetCurrentMap(sModel, sizeof(sModel));
	Format(sModel, sizeof(sModel), "maps/%s.bsp", sModel);
	SetEntityModel(iTrigger, sModel);
	ApplyNewTriggerBounds(zoneData);
	//SetEntProp(iTrigger, Prop_Send, "m_nSolidType", 2);
	
	// Add the EF_NODRAW flag to keep the engine from trying to render the trigger.
	new iEffects = GetEntProp(iTrigger, Prop_Send, "m_fEffects");
	iEffects |= 32;
	SetEntProp(iTrigger, Prop_Send, "m_fEffects", iEffects);

	HookSingleEntityOutput(iTrigger, "OnStartTouch", EntOut_OnTouchEvent);
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
	zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
	SaveZone(group, zoneData);
	
	if(iTrigger == INVALID_ENT_REFERENCE)
		return;
	
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
		ClearArray(group[ZG_zones]);
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

SaveZone(group[ZoneGroup], zoneData[ZoneData])
{
	SetArrayArray(group[ZG_zones], zoneData[ZD_index], zoneData[0], _:ZoneData);
}

bool:ZoneExistsWithName(group[ZoneGroup], const String:sZoneName[])
{
	new iSize = GetArraySize(group[ZG_zones]);
	new zoneData[ZoneData];
	for(new i=0;i<iSize;i++)
	{
		GetZoneByIndex(i, group, zoneData);
		if(StrEqual(sZoneName, zoneData[ZD_name], false))
			return true;
	}
	return false;
}

/**
 * Zone adding
 */
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
				PrintToChat(client, "Map Zones > Now shoot at the opposing diagonal edge of the zone or push \"e\" to set it at your feet.");
			}
			else
			{
				// Setting one point is tricky when using rotations.
				// We have to reset the rotation here.
				Array_Fill(g_ClientMenuState[client][CMS_rotation], 3, 0.0);
			
				// Show the new zone immediately
				TriggerTimer(g_hShowZonesTimer, true);
			}
		}
		else if(g_ClientMenuState[client][CMS_editState] == ZES_second)
		{
			Array_Copy(fOrigin, g_ClientMenuState[client][CMS_second], 3);
			
			// Setting one point is tricky when using rotations.
			// We have to reset the rotation here.
			Array_Fill(g_ClientMenuState[client][CMS_rotation], 3, 0.0);
			
			// Show the new zone immediately
			TriggerTimer(g_hShowZonesTimer, true);
			if(g_ClientMenuState[client][CMS_addZone])
			{
				g_ClientMenuState[client][CMS_editState] = ZES_name;
				DisplayZoneAddFinalizationMenu(client);
				PrintToChat(client, "Map Zones > Please type a name for this zone in chat. Type \"!abort\" to abort.");
			}
		}
	}
}

ResetZoneAddingState(client)
{
	g_ClientMenuState[client][CMS_addZone] = false;
	g_ClientMenuState[client][CMS_editState] = ZES_first;
	Array_Fill(g_ClientMenuState[client][CMS_first], 3, 0.0);
	Array_Fill(g_ClientMenuState[client][CMS_second], 3, 0.0);
}

SaveNewZone(client, const String:sName[])
{
	if(!g_ClientMenuState[client][CMS_addZone])
		return;

	new group[ZoneGroup];
	GetGroupByIndex(g_ClientMenuState[client][CMS_group], group);
	
	new zoneData[ZoneData];
	strcopy(zoneData[ZD_name], MAX_ZONE_NAME, sName);
	
	SaveChangedZoneCoordinates(client, zoneData);
	
	// Save the zone in this group.
	zoneData[ZD_triggerEntity] = INVALID_ENT_REFERENCE;
	zoneData[ZD_index] = GetArraySize(group[ZG_zones]);
	PushArrayArray(group[ZG_zones], zoneData[0], _:ZoneData);
	
	PrintToChat(client, "Map Zones > Added new zone \"%s\" to group \"%s\".", sName, group[ZG_name]);
	ResetZoneAddingState(client);
	
	// Create the trigger.
	if(!SetupZone(group, zoneData))
		PrintToChat(client, "Map Zones > Error creating trigger for new zone.");
	
	// Edit the new zone right away.
	g_ClientMenuState[client][CMS_zone] = zoneData[ZD_index];
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