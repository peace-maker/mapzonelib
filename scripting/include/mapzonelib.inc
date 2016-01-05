#if defined _mapzonelib_included
  #endinput
#endif
#define _mapzonelib_included

/**
 * Maximal length of a zone's name.
 */
#define MAX_ZONE_NAME 64

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
 * Called when a client selects the "Back" option in
 * the zone group's root menu.
 * Can be used to make the transition back into your own
 * menu hierachy.
 *
 * @param client   The client index.
 * @param group    The zone group name.
 * @noreturn
 */
functag public MapZoneMenuBackCB(client, const String:group[]);

/**
 * Register for the back action of the zone group menu.
 * Whenever a client wants to go back from the zone menus,
 * you're able to show your own menus again using this callback.
 *
 * @param group    The zone group name.
 * @param callback The callback function to call when a player presses the "Back" button in the zone root menu.
 * @return True if callback registered, false if no zone group with that name.
 */
native bool:MapZone_SetMenuBackAction(const String:group[], MapZoneMenuBackCB:callback);

/**
 * Set the default color of the zone beams for this group.
 *
 * @param group   The zone group name.
 * @param iColor  The RGBA colors of the laser.
 * @return        True if set, false if no zone group with that name.
 */
native bool:MapZone_SetZoneDefaultColor(const String:group[], const iColor[4]);

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
	MarkNativeAsOptional("MapZone_SetMenuBackAction");
	MarkNativeAsOptional("MapZone_GetGroupZones");
	MarkNativeAsOptional("MapZone_IsClusteredZone");
	MarkNativeAsOptional("MapZone_GetClusterZones");
}
#endif