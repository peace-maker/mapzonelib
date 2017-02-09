#if defined _mapzonelib_included
  #endinput
#endif
#define _mapzonelib_included

/**
 * Maximal length of a zone group's name.
 */
#define MAX_ZONE_GROUP_NAME 64

/**
 * Maximal length of a zone's name.
 */
#define MAX_ZONE_NAME 64

/**
 * If the zone is composed out of several zones or stands alone.
 */
enum MapZoneType
{
	MapZoneType_Zone,
	MapZoneType_Cluster
};

/**
 * Register a new group of zones.
 * Zones created in this group will be saved in a 
 * seperate folder in "configs/mapzonelib/<group>/mapname.zones".
 *
 * If there already are zones saved for that group, they are loaded.
 *
 * @param group    The name of the group.
 * @noreturn
 */
native MapZone_RegisterZoneGroup(const String:group[]);

/**
 * Shows the zone editing admin menu to a client.
 * The client will be able to add, modify and remove
 * zones in the group.
 *
 * @param client   The client index.
 * @param group    The zone group name.
 * @return         True if menu was shown, false if no zone group with that name.
 */
native bool:MapZone_ShowMenu(client, const String:group[]);

/**
 * Show the edit menu of a zone or cluster right away.
 *
 * @param client    The client index.
 * @param group     The zone group name.
 * @param zoneName  The name of the zone or cluster.
 * @noreturn
 */
native MapZone_ShowZoneEditMenu(client, const String:group[], const String:zoneName[]);

/**
 * Called when a client selects the "Back" option in
 * the zone group's root menu.
 * Can be used to make the transition back into your own
 * menu hierachy.
 *
 * @param client   The client index.
 * @param reason   The reason why the menu got cancelled. One of the default MenuCancel_* values.
 * @param group    The zone group name.
 * @noreturn
 */
functag public MapZoneMenuCancelCB(client, reason, const String:group[]);

/**
 * Register for the cancel action of the zone group menu.
 * Whenever a client cancels the menu or wants to go back from the zone menus,
 * you're able to show your own menus again or do other cleanup using this callback.
 *
 * @param group    The zone group name.
 * @param callback The callback function to call when the zone root menu is cancelled.
 * @return True if callback registered, false if no zone group with that name.
 */
native bool:MapZone_SetMenuCancelAction(const String:group[], MapZoneMenuCancelCB:callback);

/**
 * Start adding a zone in a zone group. Opens the edit menu afterwards.
 * The name can optionally already be provided, so the user skips the naming.
 *
 * @param client    The client index.
 * @param group     The zone group name.
 * @param zoneName  Optional: The name of the new zone.
 * @noreturn
 */
native MapZone_StartAddingZone(client, const String:group[], const String:sZoneName[] = "");

/**
 * Set the default color of the zone beams for this group.
 *
 * @param group   The zone group name.
 * @param iColor  The RGBA colors of the laser.
 * @return        True if set, false if no zone group with that name.
 */
native bool:MapZone_SetZoneDefaultColor(const String:group[], const iColor[4]);

/**
 * Set the color of the zone.
 *
 * @param zoneName  The zone group name.
 * @param group     The zone or cluster name.
 * @param iColor    The RGBA colors of the laser.
 * @return          True if set, false if no zone group or zone with that name.
 */
native bool:MapZone_SetZoneColor(const String:group[], const String:zoneName[], const iColor[4]);

/**
 * Show or hide a zone per client.
 *
 * @param zoneName  The zone group name.
 * @param group     The zone or cluster name.
 * @param client    The client to change the visibility of the zone for.
 * @param bVisible  True to show the zone to the client, false to hide.
 * @return          True when changed, false if no zone group or zone with that name.
 * @error           Invalid client index.
 */
native bool:MapZone_SetClientZoneVisibility(const String:group[], const String:zoneName[], client, bool bVisible);

/**
 * Check if a zone with that name exists in a zone group.
 *
 * @param group     The zone group name.
 * @param zoneName  The zone or cluster name.
 * @return          True if there is zone or cluster with that name in the group, false otherwise.
 */
native bool:MapZone_ZoneExists(const String:group[], const String:zoneName[]);

/**
 * Get an adt_array of zone (and cluster) names of this group.
 * Zone names are at most MAX_ZONE_NAME long.
 * 
 * You have to close the handle using CloseHandle after use.
 *
 * @param group             The zone group name.
 * @param bIncludeClusters  Include clustered zones in this list?
 * @return                  Handle to adt_array containing zone and cluster names
 *                          or INVALID_HANDLE if group doesn't exist.
 */
native Handle:MapZone_GetGroupZones(const String:group[], bool:bIncludeClusters=true);

/**
 * Check if a zone is made of several smaller zones.
 *
 * @param group    The zone group name.
 * @param zoneName The name of the zone to check for clustering.
 * @return         True if zone is a cluster, false otherwise.
 */
native bool:MapZone_IsClusteredZone(const String:group[], const String:zoneName[]);

/**
 * Get an adt_array of zone names of zones in this cluster.
 * Zone names are at most MAX_ZONE_NAME long.
 * You have to close the handle using CloseHandle after use.
 *
 * @param group        The zone group name.
 * @param clusterName  The cluster name.
 * @return             Handle to adt_array containing zone names 
 *                     or INVALID_HANDLE if group or cluster doesn't exist.
 */
native Handle:MapZone_GetClusterZones(const String:group[], const String:clusterName[]);

/**
 * Get the value of a custom key for a zone or cluster.
 *
 * @param group		The zone group name.
 * @param zoneName	The zone or cluster name.
 * @param key		The custom key.
 * @param value		The buffer to store the value in.
 * @param maxlne	The length of the value buffer.
 * @return			True if key was found and value was retrieved, false if no group or zone with that name or no keyvalue for that key.
 */
native bool:MapZone_GetCustomString(const String:group[], const String:zoneName[], const String:key[], String:value[], maxlen);

/**
 * Set the value of a custom key for a zone or cluster.
 * When the key is set with an empty string as value,
 * the key is removed from the zone.
 *
 * @param group		The zone group name.
 * @param zoneName	The zone or cluster name.
 * @param key		The custom key.
 * @param value		The new value associated with the key.
 * @return			True if value was written, false if no group or zone with that name.
 */
native bool:MapZone_SetCustomString(const String:group[], const String:zoneName[], const String:key[], const String:value[]);

/**
 * Called when a client enteres a zone.
 * 
 * @param client      The client index.
 * @param sZoneGroup  The group name of the group containing the zone.
 * @param sZoneName   The name of the zone.
 * @noreturn
 */
forward MapZone_OnClientEnterZone(client, const String:sZoneGroup[], const String:sZoneName[]);

/**
 * Called when a client leaves a zone.
 * 
 * @param client      The client index.
 * @param sZoneGroup  The name of the group containing the zone.
 * @param sZoneName   The name of the zone.
 * @noreturn
 */
forward MapZone_OnClientLeaveZone(client, const String:sZoneGroup[], const String:sZoneName[]);


/**
 * Called when a zone or cluster was created on the map.
 * This is called for every zone when loading the zones from the configs or database.
 * Zones in a cluster don't get mentioned in this forward, but only the cluster they are in.
 * When removing a zone from a cluster this forward gets called with the - now - standalone zone.
 *
 * @param sZoneGroup  The name of the group the zone was created in.
 * @param sZoneName   The name of the zone.
 * @param type        The type of the zone (Zone or Cluster).
 * @param iCreator    The client index of the user who created that zone or 0 if it has been loaded from elsewhere.
 * @noreturn
 */
forward MapZone_OnZoneCreated(const String:sZoneGroup[], const String:sZoneName[], MapZoneType:type, iCreator);


/**
 * Called when a zone or cluster was removed from the map.
 * When removing a cluster including the contained zones, this only fires for the cluster
 * and not for every single contained zone.
 *
 * This gets called for the zone which just got assigned to a cluster too,
 * since it's no longer there on its own.
 *
 * @param sZoneGroup  The name of the group the zone was removed from.
 * @param sZoneName   The name of the zone.
 * @param type        The type of the zone (Zone or Cluster).
 * @param iCreator    The client index of the user who removed that zone.
 * @noreturn
 */
forward MapZone_OnZoneRemoved(const String:sZoneGroup[], const String:sZoneName[], MapZoneType:type, iRemover);

public SharedPlugin:__pl_mapzonelib = 
{
	name = "mapzonelib",
	file = "mapzonelib.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public __pl_mapzonelib_SetNTVOptional()
{
	MarkNativeAsOptional("MapZone_RegisterZoneGroup");
	MarkNativeAsOptional("MapZone_ShowMenu");
	MarkNativeAsOptional("MapZone_ShowZoneEditMenu");
	MarkNativeAsOptional("MapZone_SetMenuCancelAction");
	MarkNativeAsOptional("MapZone_StartAddingZone");
	MarkNativeAsOptional("MapZone_SetZoneDefaultColor");
	MarkNativeAsOptional("MapZone_SetZoneColor");
	MarkNativeAsOptional("MapZone_ZoneExists");
	MarkNativeAsOptional("MapZone_GetGroupZones");
	MarkNativeAsOptional("MapZone_IsClusteredZone");
	MarkNativeAsOptional("MapZone_GetClusterZones");
	MarkNativeAsOptional("MapZone_GetCustomString");
	MarkNativeAsOptional("MapZone_SetCustomString");
}
#endif