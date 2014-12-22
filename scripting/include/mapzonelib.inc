#if defined _mapzonelib_included
  #endinput
#endif
#define _mapzonelib_included

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
}
#endif