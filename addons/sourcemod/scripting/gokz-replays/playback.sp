/*
	Bot replay playback logic and processes.
	
	The recorded files are read and their information and tick data
	stored into variables. A bot is then used to playback the recorded
	data by setting it's origin, velocity, etc. in OnPlayerRunCmd.
*/



static int preAndPostRunTickCount;

static int playbackTick[RP_MAX_BOTS];
static ArrayList playbackTickData[RP_MAX_BOTS];
static ArrayList playbackNetStats[RP_MAX_BOTS];
static ArrayList playbackWeapons[RP_MAX_BOTS];

// When tickStreamActive[bot] is true, ticks are not preloaded into playbackTickData[bot],
// they are decoded on demand from the file using a small sliding window backed by a keyframe index.
static bool tickStreamActive[RP_MAX_BOTS];
static File tickStreamFile[RP_MAX_BOTS];
static int tickStreamPayloadStart[RP_MAX_BOTS];
static int tickStreamTickCount[RP_MAX_BOTS];
static ArrayList tickStreamKeyframes[RP_MAX_BOTS]; // entries: int[2] = {tickIndex, payloadOffset}
static ArrayList tickStreamWindow[RP_MAX_BOTS];
static int tickStreamWindowStart[RP_MAX_BOTS];
static int tickStreamCursor[RP_MAX_BOTS];
static bool tickStreamFileAtCursor[RP_MAX_BOTS];
static any tickStreamAccum[RP_MAX_BOTS][RP_V2_TICK_DATA_BLOCKSIZE];
static bool inBreather[RP_MAX_BOTS];
static float breatherStartTime[RP_MAX_BOTS];

// Original bot caller, needed for OnClientPutInServer callback
static int botCaller[RP_MAX_BOTS];
// Original bot name after creation by bot_add, needed for bot removal
static char botName[RP_MAX_BOTS][MAX_NAME_LENGTH];
static bool botInGame[RP_MAX_BOTS];
static int botClient[RP_MAX_BOTS];
static bool botDataLoaded[RP_MAX_BOTS];
static int botReplayType[RP_MAX_BOTS];
static int botReplayVersion[RP_MAX_BOTS];
static int botSteamAccountID[RP_MAX_BOTS];
static int botCourse[RP_MAX_BOTS];
static int botMode[RP_MAX_BOTS];
static int botStyle[RP_MAX_BOTS];
static float botTime[RP_MAX_BOTS];
static int botTimeTicks[RP_MAX_BOTS];
static char botAlias[RP_MAX_BOTS][MAX_NAME_LENGTH];
static bool botPaused[RP_MAX_BOTS];
static bool botPlaybackPaused[RP_MAX_BOTS];
static int botKnife[RP_MAX_BOTS];
static int botWeapon[RP_MAX_BOTS];
static int botJumpType[RP_MAX_BOTS];
static float botJumpDistance[RP_MAX_BOTS];
static int botJumpBlockDistance[RP_MAX_BOTS];

static int timeOnGround[RP_MAX_BOTS];
static int timeInAir[RP_MAX_BOTS];
static int botTeleportsUsed[RP_MAX_BOTS];
static int botCurrentTeleport[RP_MAX_BOTS];
static int botButtons[RP_MAX_BOTS];
static MoveType botMoveType[RP_MAX_BOTS];
static float botTakeoffSpeed[RP_MAX_BOTS];
static float botSpeed[RP_MAX_BOTS];
static float botLastOrigin[RP_MAX_BOTS][3];
static bool hitBhop[RP_MAX_BOTS];
static bool hitPerf[RP_MAX_BOTS];
static bool botJumped[RP_MAX_BOTS];
static bool botIsTakeoff[RP_MAX_BOTS];
static bool botJustTeleported[RP_MAX_BOTS];
static float botLandingSpeed[RP_MAX_BOTS];



// =====[ PUBLIC ]=====

// Returns the client index of the replay bot, or -1 otherwise
int LoadReplayBot(int client, char[] path)
{
	// Safeguard Check
	if (GOKZ_GetCoreOption(client, Option_Safeguard) > Safeguard_Disabled && GOKZ_GetTimerRunning(client) && GOKZ_GetValidTimer(client))
	{
		if (!GOKZ_GetPaused(client) && !GOKZ_GetCanPause(client))
		{
			GOKZ_PrintToChat(client, true, "%t", "Safeguard - Blocked");
			GOKZ_PlayErrorSound(client);
			return -1;
		}
	}
	int bot;
	if (GetBotsInUse() < RP_MAX_BOTS)
	{
		bot = GetUnusedBot();
	}
	else
	{
		GOKZ_PrintToChat(client, true, "%t", "No Bots Available");
		GOKZ_PlayErrorSound(client);
		return -1;
	}
	
	if (bot == -1)
	{
		LogError("Unused bot could not be found even though only %d out of %d are known to be in use.", 
				 GetBotsInUse(), RP_MAX_BOTS);
		GOKZ_PlayErrorSound(client);
		return -1;
	}

	if (!LoadPlayback(client, bot, path))
	{
		GOKZ_PlayErrorSound(client);
		return -1;
	}
	
	ServerCommand("bot_add");
	botCaller[bot] = client;
	return botClient[bot];
}

// Passes the current state of the replay into the HUDInfo struct
void GetPlaybackState(int client, HUDInfo info)
{
	int bot, i;
	for(i = 0; i < RP_MAX_BOTS; i++)
	{
		bot = botClient[i] == client ? i : bot;
	}
	if (i == RP_MAX_BOTS + 1) return;
	
	if (!Tick_IsLoaded(bot))
	{
		return;
	}
	
	info.TimerRunning = botReplayType[bot] == ReplayType_Jump ? false : true;
	if (botReplayVersion[bot] == 1)
	{
		info.Time = playbackTick[bot]  * GetTickInterval();
	}
	else if (botReplayVersion[bot] >= 2)
	{
		if (playbackTick[bot] < preAndPostRunTickCount)
		{
			info.Time = 0.0;
		}
		else if (playbackTick[bot] >= Tick_Length(bot) - preAndPostRunTickCount)
		{
			info.Time = botTime[bot];
		}
		else if (playbackTick[bot] >= preAndPostRunTickCount)
		{
			info.Time = (playbackTick[bot] - preAndPostRunTickCount) * GetTickInterval();
		}
	}
	info.TimerRunning = true;
	info.TimeType = botTeleportsUsed[bot] > 0 ? TimeType_Nub : TimeType_Pro;
	info.Speed = botSpeed[bot];
	info.Paused = false;
	info.OnLadder = (botMoveType[bot] == MOVETYPE_LADDER);
	info.Noclipping = false;
	info.OnGround = Movement_GetOnGround(client);
	info.Ducking = botButtons[bot] & IN_DUCK > 0;
	info.ID = botClient[bot];
	info.Jumped = botJumped[bot];
	info.HitBhop = hitBhop[bot];
	info.HitPerf = hitPerf[bot];
	info.Buttons = botButtons[bot];
	info.TakeoffSpeed = botTakeoffSpeed[bot];
	info.IsTakeoff = botIsTakeoff[bot] && !Movement_GetOnGround(client);
	info.CurrentTeleport = botCurrentTeleport[bot];
}

int GetBotFromClient(int client)
{
	for (int bot = 0; bot < RP_MAX_BOTS; bot++)
	{
		if (botClient[bot] == client)
		{
			return bot;
		}
	}
	return -1;
}

bool InBreather(int bot)
{
	return inBreather[bot];
}

bool PlaybackPaused(int bot)
{
	return botPlaybackPaused[bot];
}

void PlaybackTogglePause(int bot)
{
	if(botPlaybackPaused[bot])
	{
		botPlaybackPaused[bot] = false;
	}
	else
	{
		botPlaybackPaused[bot] = true;
	}
}

void PlaybackSkipForward(int bot)
{
	if (playbackTick[bot] + RoundToZero(RP_SKIP_TIME / GetTickInterval()) < Tick_Length(bot))
	{
		PlaybackSkipToTick(bot, playbackTick[bot] + RoundToZero(RP_SKIP_TIME / GetTickInterval()));
	}
}

void PlaybackSkipBack(int bot)
{
	if (playbackTick[bot] < RoundToZero(RP_SKIP_TIME / GetTickInterval()))
	{
		PlaybackSkipToTick(bot, 0);
	}
	else
	{
		PlaybackSkipToTick(bot, playbackTick[bot] - RoundToZero(RP_SKIP_TIME / GetTickInterval()));
	}
}

int PlaybackGetTeleports(int bot)
{
	return botCurrentTeleport[bot];
}

void TrySkipToTime(int client, int seconds)
{
	if (!IsValidClient(client))
	{
		return;
	}
	
	int tick = seconds * 128 + preAndPostRunTickCount;
	int bot = GetBotFromClient(GetObserverTarget(client));
	
	if (tick >= 0 && tick < Tick_Length(bot))
	{
		PlaybackSkipToTick(bot, tick);
	}
	else
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Controls - Invalid Time");
	}
}

float GetPlaybackTime(int bot)
{
	if (playbackTick[bot] < preAndPostRunTickCount)
	{
		return 0.0;
	}
	if (playbackTick[bot] >= Tick_Length(bot) - preAndPostRunTickCount)
	{
		return botTime[bot];
	}
	if (playbackTick[bot] >= preAndPostRunTickCount)
	{
		return (playbackTick[bot] - preAndPostRunTickCount) * GetTickInterval();
	}

	return 0.0;
}



// =====[ EVENTS ]=====

void OnClientPutInServer_Playback(int client)
{
	if (!IsFakeClient(client) || IsClientSourceTV(client))
	{
		return;
	}
	
	// Check if an unassigned bot has joined, and assign it
	for (int bot; bot < RP_MAX_BOTS; bot++)
	{
		// Also check if the bot was created by us.
		if (!botInGame[bot] && botCaller[bot] != 0)
		{
			botInGame[bot] = true;
			botClient[bot] = client;
			GetClientName(client, botName[bot], sizeof(botName[]));
			// The bot won't receive its weapons properly if we don't wait a frame
			RequestFrame(SetBotStuff, bot);
			if (IsValidClient(botCaller[bot]))
			{
				MakePlayerSpectate(botCaller[bot], botClient[bot]);
				botCaller[bot] = 0;
			}
			break;
		}
	}
}

void OnClientDisconnect_Playback(int client)
{
	for (int bot; bot < RP_MAX_BOTS; bot++)
	{
		if (botClient[bot] != client)
		{
			continue;
		}
		
		botInGame[bot] = false;
		if (Tick_IsLoaded(bot))
		{
			Tick_Free(bot);
			botDataLoaded[bot] = false;
		}
		if (playbackNetStats[bot] != null)
		{
			playbackNetStats[bot].Clear();
		}
		if (playbackWeapons[bot] != null)
		{
			playbackWeapons[bot].Clear();
		}
	}
}

void OnPlayerRunCmd_Playback(int client, int &buttons, float vel[3], float angles[3])
{
	if (!IsFakeClient(client))
	{
		return;
	}
	
	for (int bot; bot < RP_MAX_BOTS; bot++)
	{
		// Check if not the bot we're looking for
		if (!botInGame[bot] || botClient[bot] != client || !botDataLoaded[bot])
		{
			continue;
		}

		switch (botReplayVersion[bot])
		{
			case 1: PlaybackVersion1(client, bot, buttons);
			case 2, 3: PlaybackVersion2(client, bot, buttons, vel, angles);
		}
		break;
	}
}

void OnPlayerRunCmdPost_Playback(int client)
{
	for (int bot; bot < RP_MAX_BOTS; bot++)
	{
		// Check if not the bot we're looking for
		if (!botInGame[bot] || botClient[bot] != client || !botDataLoaded[bot])
		{
			continue;
		}
		if (botReplayVersion[bot] >= 2)
		{
			PlaybackVersion2Post(client, bot);
		}
		break;
	}
}

void GOKZ_OnOptionsLoaded_Playback(int client)
{
	for (int bot = 0; bot < RP_MAX_BOTS; bot++)
	{
		if (botClient[bot] == client)
		{
			// Reset its movement options as it might be wrongfully changed
			GOKZ_SetCoreOption(client, Option_Mode, botMode[bot]);
			GOKZ_SetCoreOption(client, Option_Style, botStyle[bot]);
		}
	}
}
// =====[ PRIVATE ]=====

// Returns false if there was a problem loading the playback e.g. doesn't exist
static bool LoadPlayback(int client, int bot, char[] path)
{
	if (!FileExists(path))
	{
		GOKZ_PrintToChat(client, true, "%t", "No Replay Found");
		return false;
	}

	File file = OpenFile(path, "rb");
	
	// Check magic number in header
	int magicNumber;
	file.ReadInt32(magicNumber);
	if (magicNumber != RP_MAGIC_NUMBER)
	{
		LogError("Failed to load invalid replay file: \"%s\".", path);
		delete file;
		return false;
	}
	
	// Check replay format version
	int formatVersion;
	file.ReadInt8(formatVersion);
	switch(formatVersion)
	{
		case 1:
		{
			botReplayVersion[bot] = 1;
			if (!LoadFormatVersion1Replay(file, bot))
			{
				return false;
			}
		}
		case 2:
		{
			botReplayVersion[bot] = 2;
			if (!LoadFormatVersion2Or3Replay(file, client, bot, 2))
			{
				return false;
			}
		}
		case 3:
		{
			botReplayVersion[bot] = 3;
			if (!LoadFormatVersion2Or3Replay(file, client, bot, 3))
			{
				return false;
			}
		}

		default:
		{
			LogError("Failed to load replay file with unsupported format version: \"%s\".", path);
			delete file;
			return false;
		}
	}

	return true;
}

static bool LoadFormatVersion1Replay(File file, int bot)
{	
	// Old replays only support runs, not jumps
	botReplayType[bot] = ReplayType_Run;

	int length;

	// GOKZ version
	file.ReadInt8(length);
	char[] gokzVersion = new char[length + 1];
	file.ReadString(gokzVersion, length, length);
	gokzVersion[length] = '\0';
	
	// Map name 
	file.ReadInt8(length);
	char[] mapName = new char[length + 1];
	file.ReadString(mapName, length, length);
	mapName[length] = '\0';
	
	// Some integers...
	file.ReadInt32(botCourse[bot]);
	file.ReadInt32(botMode[bot]);
	file.ReadInt32(botStyle[bot]);
	
	// Old replays don't store the weapon information
	botKnife[bot] = CS_WeaponIDToItemDefIndex(CSWeapon_KNIFE);
	botWeapon[bot] = (botMode[bot] == Mode_Vanilla) ? -1 : CS_WeaponIDToItemDefIndex(CSWeapon_USP_SILENCER);
	
	// Time
	int timeAsInt;
	file.ReadInt32(timeAsInt);
	botTime[bot] = view_as<float>(timeAsInt);
	
	// Some integers...
	file.ReadInt32(botTeleportsUsed[bot]);
	file.ReadInt32(botSteamAccountID[bot]);
	
	// SteamID2 
	file.ReadInt8(length);
	char[] steamID2 = new char[length + 1];
	file.ReadString(steamID2, length, length);
	steamID2[length] = '\0';
	
	// IP
	file.ReadInt8(length);
	char[] IP = new char[length + 1];
	file.ReadString(IP, length, length);
	IP[length] = '\0';
	
	// Alias
	file.ReadInt8(length);
	file.ReadString(botAlias[bot], sizeof(botAlias[]), length);
	botAlias[bot][length] = '\0';
	
	// Read tick data
	file.ReadInt32(length);
	
	// Setup playback tick data array list
	if (playbackTickData[bot] == null)
	{
		playbackTickData[bot] = new ArrayList(IntMax(RP_V1_TICK_DATA_BLOCKSIZE, sizeof(ReplayTickData)), length);
	}
	else
	{  // Make sure it's all clear and the correct size
		playbackTickData[bot].Clear();
		playbackTickData[bot].Resize(length);
	}

	// The replay has no replay data, this shouldn't happen normally,
	// but this would cause issues in other code, so we don't even try to load this.
	if (length == 0)
	{
		delete file;
		return false;
	}
	
	any tickData[RP_V1_TICK_DATA_BLOCKSIZE];
	for (int i = 0; i < length; i++)
	{
		file.Read(tickData, RP_V1_TICK_DATA_BLOCKSIZE, 4);
		playbackTickData[bot].Set(i, view_as<float>(tickData[0]), 0); // origin[0]
		playbackTickData[bot].Set(i, view_as<float>(tickData[1]), 1); // origin[1]
		playbackTickData[bot].Set(i, view_as<float>(tickData[2]), 2); // origin[2]
		playbackTickData[bot].Set(i, view_as<float>(tickData[3]), 3); // angles[0]
		playbackTickData[bot].Set(i, view_as<float>(tickData[4]), 4); // angles[1]
		playbackTickData[bot].Set(i, view_as<int>(tickData[5]), 5); // buttons
		playbackTickData[bot].Set(i, view_as<int>(tickData[6]), 6); // flags
	}
	
	playbackTick[bot] = 0;
	botDataLoaded[bot] = true;
	
	delete file;
	return true;
}

static bool LoadFormatVersion2Or3Replay(File file, int client, int bot, int formatVersion)
{
	int length;

	// Replay type
	int replayType;
	file.ReadInt8(replayType);

	// GOKZ version
	file.ReadInt8(length);
	char[] gokzVersion = new char[length + 1];
	file.ReadString(gokzVersion, length, length);
	gokzVersion[length] = '\0';
	
	// Map name 
	file.ReadInt8(length);
	char[] mapName = new char[length + 1];
	file.ReadString(mapName, length, length);
	mapName[length] = '\0';
	if (!StrEqual(mapName, gC_CurrentMap))
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - Wrong Map", mapName);
		delete file;
		return false;
	}

	// Map filesize
	int mapFileSize;
	file.ReadInt32(mapFileSize);

	// Server IP
	int serverIP;
	file.ReadInt32(serverIP);

	// Timestamp
	int timestamp;
	file.ReadInt32(timestamp);

	// Player Alias
	file.ReadInt8(length);
	file.ReadString(botAlias[bot], sizeof(botAlias[]), length);
	botAlias[bot][length] = '\0';

	// Player Steam ID
	int steamID;
	file.ReadInt32(steamID);

	// Mode
	file.ReadInt8(botMode[bot]);

	// Style
	file.ReadInt8(botStyle[bot]);

	// Player Sensitivity
	int intPlayerSensitivity;
	file.ReadInt32(intPlayerSensitivity);
	float playerSensitivity = view_as<float>(intPlayerSensitivity);

	// Player MYAW
	int intPlayerMYaw;
	file.ReadInt32(intPlayerMYaw);
	float playerMYaw = view_as<float>(intPlayerMYaw);

	// Tickrate
	int tickrateAsInt;
	file.ReadInt32(tickrateAsInt);
	float tickrate = view_as<float>(tickrateAsInt);
	if (tickrate != RoundToZero(1 / GetTickInterval()))
	{
		GOKZ_PrintToChat(client, true, "%t", "Replay Menu - Wrong Tickrate", tickrate, (RoundToZero(1 / GetTickInterval())));
		delete file;
		return false;
	}

	// Tick Count
	int tickCount;
	file.ReadInt32(tickCount);

	// The replay has no replay data, this shouldn't happen normally,
	// but this would cause issues in other code, so we don't even try to load this.
	if (tickCount == 0)
	{
		delete file;
		return false;
	}

	// Equipped Weapon
	file.ReadInt32(botWeapon[bot]);
	
	// Equipped Knife
	file.ReadInt32(botKnife[bot]);

	// Big spit to console
	PrintToConsole(client, "Replay Type: %d\nGOKZ Version: %s\nMap Name: %s\nMap Filesize: %d\nServer IP: %d\nTimestamp: %d\nPlayer Alias: %s\nPlayer Steam ID: %d\nMode: %d\nStyle: %d\nPlayer Sensitivity: %f\nPlayer m_yaw: %f\nTickrate: %f\nTick Count: %d\nWeapon: %d\nKnife: %d", replayType, gokzVersion, mapName, mapFileSize, serverIP, timestamp, botAlias[bot], steamID, botMode[bot], botStyle[bot], playerSensitivity, playerMYaw, tickrate, tickCount, botWeapon[bot], botKnife[bot]);

	switch(replayType)
	{
		case ReplayType_Run:
		{
			// Time
			int timeAsInt;
			file.ReadInt32(timeAsInt);
			botTime[bot] = view_as<float>(timeAsInt);
			botTimeTicks[bot] = RoundToNearest(botTime[bot] * tickrate);

			// Course
			file.ReadInt8(botCourse[bot]);

			// Teleports Used
			file.ReadInt32(botTeleportsUsed[bot]);

			// Type
			botReplayType[bot] = ReplayType_Run;
			
			// Finish spit to console
			PrintToConsole(client, "Time: %f\nCourse: %d\nTeleports Used: %d", botTime[bot], botCourse[bot], botTeleportsUsed[bot]);
		}
		case ReplayType_Cheater:
		{
			// Reason
			int reason;
			file.ReadInt8(reason);
			
			// Type
			botReplayType[bot] = ReplayType_Cheater;

			// Finish spit to console
			PrintToConsole(client, "AC Reason: %s", gC_ACReasons[reason]);
		}
		case ReplayType_Jump:
		{
			// Jump Type
			file.ReadInt8(botJumpType[bot]);

			// Distance
			file.ReadInt32(view_as<int>(botJumpDistance[bot]));

			// Block Distance
			file.ReadInt32(botJumpBlockDistance[bot]);

			// Strafe Count
			int strafeCount;
			file.ReadInt8(strafeCount);

			// Sync
			float sync;
			file.ReadInt32(view_as<int>(sync));

			// Pre
			float pre;
			file.ReadInt32(view_as<int>(pre));

			// Max
			float max;
			file.ReadInt32(view_as<int>(max));

			// Airtime
			int airtime;
			file.ReadInt32(airtime);

			// Type
			botReplayType[bot] = ReplayType_Jump;

			// Finish spit to console
			PrintToConsole(client, "Jump Type: %s\nJump Distance: %f\nBlock Distance: %d\nStrafe Count: %d\nSync: %f\n Pre: %f\nMax: %f\nAirtime: %d", 
				gC_JumpTypes[botJumpType[bot]], botJumpDistance[bot], botJumpBlockDistance[bot], strafeCount, sync, pre, max, airtime);
		}
	}

	// Tick Data
	// v3 streams ticks on demand and never populates playbackTickData[bot].
	if (formatVersion < 3)
	{
		if (playbackTickData[bot] == null)
		{
			playbackTickData[bot] = new ArrayList(IntMax(RP_V1_TICK_DATA_BLOCKSIZE, sizeof(ReplayTickData)));
		}
		else
		{
			playbackTickData[bot].Clear();
		}
	}
	
	// Read tick data
	preAndPostRunTickCount = RoundToZero(RP_PLAYBACK_BREATHER_TIME / GetTickInterval());

	if (formatVersion >= 3)
	{
		if (!ReadV3SectionStream(file, bot, tickCount))
		{
			TickStream_Free(bot);
			delete file;
			return false;
		}
	}
	else
	{
		// v2: tick stream runs to EOF. -1 = no cap, refill until file ends.
		ReadCache_SetFile(file, -1);
		ReadTickStreamV2Format(bot, tickCount);
	}

	playbackTick[bot] = 0;
	botDataLoaded[bot] = true;

	// streaming keeps the file handle open via tickStreamFile[bot].
	if (!tickStreamActive[bot])
	{
		delete file;
	}

	return true;
}

static void ReadTickStreamV2Format(int bot, int tickCount)
{
	// Caller must call ReadCache_SetFile(file, ...) before invoking this function.
	any tickData[RP_V2_TICK_DATA_BLOCKSIZE];
	for (int i = 0; i < tickCount; i++)
	{
		if (!ReadCache_ReadInt32(tickData[RPDELTA_DELTAFLAGS]))
		{
			break;
		}

		for (int index = 1; index < sizeof(tickData); index++)
		{
			int currentFlag = (1 << index);
			if (tickData[RPDELTA_DELTAFLAGS] & currentFlag)
			{
				ReadCache_ReadInt32(tickData[index]);
			}
		}
		
		// HACK: Jump replays don't record proper length sometimes. I don't know why.
		//		 This leads to oversized replays full of 0s at the end.
		// 		 So, we do this horrible check to dodge that issue.
		if (tickData[RPDELTA_ORIGIN_X] == 0 && tickData[RPDELTA_ORIGIN_Y] == 0 && tickData[RPDELTA_ORIGIN_Z] == 0
			&& tickData[RPDELTA_ANGLES_X] == 0 && tickData[RPDELTA_ANGLES_Y] == 0)
		{
			break;
		}
		playbackTickData[bot].PushArray(tickData);
	}
}

static bool ReadV3SectionStream(File file, int bot, int tickCount)
{
	for (;;)
	{
		int tag;
		if (!file.ReadInt32(tag))
		{
			// EOF without an explicit terminator is tolerated.
			return true;
		}
		if (tag == RP_SECTION_END)
		{
			return true;
		}

		int codec;
		int length;
		int uncompressedLength;
		if (!file.ReadInt8(codec)
			|| !file.ReadInt32(length)
			|| !file.ReadInt32(uncompressedLength))
		{
			LogError("Truncated section header (tag %d).", tag);
			return false;
		}

		int payloadStart = file.Position;

		switch (tag)
		{
			case RP_SECTION_TICKS:
			{
				if (codec == RP_CODEC_RAW)
				{
					// File handle ownership transfers to TickStream and must NOT be deleted by caller.
					if (!TickStream_Init(bot, file, payloadStart, length, tickCount))
					{
						LogError("Failed to initialize tick stream for bot %d.", bot);
						return false;
					}
				}
				else
				{
					LogError("Unknown codec %d for TICKS section, skipping.", codec);
				}
			}
			case RP_SECTION_NETSTATS:
			{
				if (codec == RP_CODEC_RAW)
				{
					ReadCache_SetFile(file, length);
					ReadNetStatsSection(bot);
				}
				else
				{
					LogError("Unknown codec %d for NETSTATS section, skipping.", codec);
				}
			}
			case RP_SECTION_WEAPONS:
			{
				if (codec == RP_CODEC_RAW)
				{
					ReadCache_SetFile(file, length);
					ReadWeaponsSection(bot);
				}
				else
				{
					LogError("Unknown codec %d for WEAPONS section, skipping.", codec);
				}
			}
			// Future tags fall through below.
		}

		// Always advance to end of payload to handle unknown tags, unknown codecs,
		// the v2 tick reader's early-break HACK, and any bytes the read cache pulled past the actual consumer position.
		file.Seek(payloadStart + length, SEEK_SET);
	}
}

static void ReadNetStatsSection(int bot)
{
	if (playbackNetStats[bot] == null)
	{
		playbackNetStats[bot] = new ArrayList(sizeof(ReplayNetStats));
	}
	else
	{
		playbackNetStats[bot].Clear();
	}

	int n;
	if (!ReadCache_ReadInt32(n) || n < 0)
	{
		return;
	}

	playbackNetStats[bot].Resize(n);

	ReplayNetStats netStats;
	for (int i = 0; i < n; i++)
	{
		int latencyMs;
		int lossIn, lossOut;
		int chokeIn, chokeOut;
		if (!ReadCache_ReadInt16(latencyMs)
			|| !ReadCache_ReadInt16(lossIn)
			|| !ReadCache_ReadInt16(lossOut)
			|| !ReadCache_ReadInt16(chokeIn)
			|| !ReadCache_ReadInt16(chokeOut))
		{
			LogError("Truncated NETSTATS at entry %d/%d.", i, n);
			playbackNetStats[bot].Resize(i);
			return;
		}
		netStats.latencyMs = latencyMs;
		netStats.lossInX10k = lossIn;
		netStats.lossOutX10k = lossOut;
		netStats.chokeInX10k = chokeIn;
		netStats.chokeOutX10k = chokeOut;
		playbackNetStats[bot].SetArray(i, netStats);
	}
}

static void ReadWeaponsSection(int bot)
{
	if (playbackWeapons[bot] == null)
	{
		playbackWeapons[bot] = new ArrayList(sizeof(ReplayWeaponEntry));
	}
	else
	{
		playbackWeapons[bot].Clear();
	}

	int count;
	if (!ReadCache_ReadInt8(count) || count < 0)
	{
		return;
	}

	for (int i = 0; i < count; i++)
	{
		ReplayWeaponEntry entry;

		int slot, defIndex, paintKit, seed, wearBits, statTrak;
		int nameLen;
		if (!ReadCache_ReadInt8(slot)
			|| !ReadCache_ReadInt32(defIndex)
			|| !ReadCache_ReadInt32(paintKit)
			|| !ReadCache_ReadInt32(seed)
			|| !ReadCache_ReadInt32(wearBits)
			|| !ReadCache_ReadInt32(statTrak)
			|| !ReadCache_ReadInt8(nameLen))
		{
			LogError("Truncated WEAPONS at entry %d/%d.", i, count);
			return;
		}
		entry.slot = slot;
		entry.defIndex = defIndex;
		entry.paintKit = paintKit;
		entry.seed = seed;
		entry.wear = view_as<float>(wearBits);
		entry.statTrak = statTrak;

		if (nameLen > 0)
		{
			int copyLen = nameLen;
			if (copyLen >= sizeof(ReplayWeaponEntry::nametag))
			{
				copyLen = sizeof(ReplayWeaponEntry::nametag) - 1;
			}
			ReadCache_ReadString(entry.nametag, sizeof(ReplayWeaponEntry::nametag), nameLen, copyLen);
		}

		for (int s = 0; s < RP_MAX_WEAPON_STICKERS; s++)
		{
			int kit, wear, scale, rotation;
			if (!ReadCache_ReadInt32(kit)
				|| !ReadCache_ReadInt32(wear)
				|| !ReadCache_ReadInt32(scale)
				|| !ReadCache_ReadInt32(rotation))
			{
				LogError("Truncated WEAPONS sticker at entry %d sticker %d.", i, s);
				return;
			}
			entry.stickerKit[s] = kit;
			entry.stickerWear[s] = view_as<float>(wear);
			entry.stickerScale[s] = view_as<float>(scale);
			entry.stickerRotation[s] = view_as<float>(rotation);
		}

		playbackWeapons[bot].PushArray(entry);
	}
}

// =====[ READ CACHE ]=====
//
// Mirror of recording.sp's WriteCache. Pulls bytes from disk in ~64 KB chunks instead of one IFileSystem syscall per ReadIntN.
// Bytes are packed 4-per-cell little-endian (64 KB) and bulk-loaded via file.Read(buf, n, 4)
//
// Lifecycle:
//   ReadCache_SetFile(file, sectionLength); // bind file + cap on bytes (-1 = unbounded)
//   ReadCache_ReadInt32(...); // ...repeat for whole payload...
//   file.Seek(payloadStart + sectionLength, SEEK_SET); // re-anchor file pos

#define READ_CACHE_CELLS 16384
#define READ_CACHE_BYTES (READ_CACHE_CELLS * 4)

static File readCacheFile;
static int readCache[READ_CACHE_CELLS];  // 4 bytes per cell, LE packed
static int readCacheBytes;               // valid bytes in buffer
static int readCachePos;                 // bytes consumed
static int readCacheRemaining;           // bytes still pullable from file (-1 = unbounded)

static void ReadCache_SetFile(File file, int byteCap)
{
	readCacheFile = file;
	readCacheBytes = 0;
	readCachePos = 0;
	readCacheRemaining = byteCap;
}

static bool ReadCache_Refill()
{
	readCacheBytes = 0;
	readCachePos = 0;

	if (readCacheRemaining == 0)
	{
		return false;
	}

	int maxBytes = READ_CACHE_BYTES;
	if (readCacheRemaining > 0 && maxBytes > readCacheRemaining)
	{
		maxBytes = readCacheRemaining;
	}

	// file.Read with size=4 reads 4 bytes per cell which on little-endian targets matches a per-byte stream.
	int wantCells = maxBytes >> 2;
	int gotCells = 0;
	if (wantCells > 0)
	{
		gotCells = readCacheFile.Read(readCache, wantCells, 4);
		if (gotCells < 0)
		{
			gotCells = 0;
		}
		readCacheBytes = gotCells << 2;
		if (readCacheRemaining > 0)
		{
			readCacheRemaining -= readCacheBytes;
		}
	}

	// Trailing 1-3 bytes (only at the last refill of a section whose length isn't a multiple of 4, or never if cap was already a cell-multiple).
	// Skip if file came up short on cells, it's exhausted.
	if (gotCells == wantCells)
	{
		int tail = maxBytes - readCacheBytes;
		for (int i = 0; i < tail; i++)
		{
			int b;
			if (!readCacheFile.ReadInt8(b))
			{
				break;
			}
			int byteIdx = readCacheBytes;
			int cellIdx = byteIdx >> 2;
			int shift = (byteIdx & 3) * 8;
			if (shift == 0)
			{
				readCache[cellIdx] = b & 0xFF;
			}
			else
			{
				readCache[cellIdx] |= (b & 0xFF) << shift;
			}
			readCacheBytes++;
			if (readCacheRemaining > 0)
			{
				readCacheRemaining--;
			}
		}
	}

	return readCacheBytes > 0;
}

static bool ReadCache_ReadByte(int &out)
{
	if (readCachePos >= readCacheBytes)
	{
		if (!ReadCache_Refill())
		{
			return false;
		}
	}
	int cellIdx = readCachePos >> 2;
	int shift = (readCachePos & 3) * 8;
	out = (readCache[cellIdx] >> shift) & 0xFF;
	readCachePos++;
	return true;
}

static bool ReadCache_ReadInt8(int &v)
{
	return ReadCache_ReadByte(v);
}

static bool ReadCache_ReadInt16(int &v)
{
	int b0, b1;
	if (!ReadCache_ReadByte(b0) || !ReadCache_ReadByte(b1))
	{
		return false;
	}
	v = b0 | (b1 << 8);
	return true;
}

static bool ReadCache_ReadInt32(int &v)
{
	// Pull a whole cell in one op when the byte position is cell-aligned and the cell is fully present.
	// TICKS reads only Int32s from payload offset 0, so it stays on this path end-to-end.
	if ((readCachePos & 3) == 0 && readCachePos + 4 <= readCacheBytes)
	{
		v = readCache[readCachePos >> 2];
		readCachePos += 4;
		return true;
	}

	int b0, b1, b2, b3;
	if (!ReadCache_ReadByte(b0) || !ReadCache_ReadByte(b1)
		|| !ReadCache_ReadByte(b2) || !ReadCache_ReadByte(b3))
	{
		return false;
	}
	v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
	return true;
}

// Reads `byteCount` bytes from the stream, copies up to `copyCount` of them into `buf` (NUL-terminating),
// and discards any remaining bytes. `copyCount` must be <= byteCount and <= maxLen-1.
static void ReadCache_ReadString(char[] buf, int maxLen, int byteCount, int copyCount)
{
	int stored = 0;
	for (int i = 0; i < byteCount; i++)
	{
		int b;
		if (!ReadCache_ReadByte(b))
		{
			break;
		}
		if (stored < copyCount && stored < maxLen - 1)
		{
			buf[stored++] = b;
		}
	}
	if (stored < maxLen)
	{
		buf[stored] = '\0';
	}
	else
	{
		buf[maxLen - 1] = '\0';
	}
}

// =====[ TICK STREAM ]=====
//
// At load time we read only the keyframe index trailer
// Tick data is decoded into a small sliding window around the current playback tick.
// On miss we either decode forward from the cursor (cheap, sequential play)
// or seek to the largest keyframe with tickIndex <= target (random skip).

#define TICK_WINDOW_BEHIND_TICKS 64
#define TICK_WINDOW_AHEAD_TICKS 192
#define TICK_WINDOW_MAX_TICKS 384

// Read the keyframe trailer at the end of the TICKS section payload.
// Layout: <ticks bytes...> { u32 tickIndex, u32 fileOffset } * count, u32 count.
// Returns true on success.
static bool TickStream_ReadKeyframeTrailer(File file, int payloadStart, int payloadLength, ArrayList keyframes)
{
	if (payloadLength < 4)
	{
		LogError("TICKS payload too short for keyframe trailer (%d bytes).", payloadLength);
		return false;
	}

	int countOffset = payloadStart + payloadLength - 4;
	file.Seek(countOffset, SEEK_SET);
	int count;
	if (!file.ReadInt32(count) || count < 0)
	{
		LogError("Truncated keyframe trailer count.");
		return false;
	}

	int trailerSize = 4 + count * 8;
	if (trailerSize > payloadLength)
	{
		LogError("Keyframe trailer count %d implies %d bytes but payload is only %d.", count, trailerSize, payloadLength);
		return false;
	}

	int entriesStart = payloadStart + payloadLength - trailerSize;
	file.Seek(entriesStart, SEEK_SET);
	for (int i = 0; i < count; i++)
	{
		int entry[2];
		if (!file.ReadInt32(entry[0]) || !file.ReadInt32(entry[1]))
		{
			LogError("Truncated keyframe entry %d/%d.", i, count);
			return false;
		}
		keyframes.PushArray(entry, sizeof(entry));
	}
	return true;
}

// Bind the bot to a streaming TICKS section. Takes ownership of `file` (kept open).
static bool TickStream_Init(int bot, File file, int payloadStart, int payloadLength, int tickCount)
{
	TickStream_Free(bot);

	ArrayList keyframes = new ArrayList(2);
	if (!TickStream_ReadKeyframeTrailer(file, payloadStart, payloadLength, keyframes))
	{
		delete keyframes;
		return false;
	}
	if (keyframes.Length == 0)
	{
		LogError("TICKS section has no keyframes; refusing to stream.");
		delete keyframes;
		return false;
	}

	tickStreamActive[bot] = true;
	tickStreamFile[bot] = file;
	tickStreamPayloadStart[bot] = payloadStart;
	tickStreamTickCount[bot] = tickCount;
	tickStreamKeyframes[bot] = keyframes;
	tickStreamWindow[bot] = new ArrayList(sizeof(ReplayTickData));
	tickStreamWindowStart[bot] = 0;
	tickStreamCursor[bot] = 0;
	// ReadV3SectionStream owns the file position right after Init returns and will
	// seek past this section to read the next one, so the first decode must reseek.
	tickStreamFileAtCursor[bot] = false;
	for (int i = 0; i < RP_V2_TICK_DATA_BLOCKSIZE; i++)
	{
		tickStreamAccum[bot][i] = 0;
	}
	return true;
}

static void TickStream_Free(int bot)
{
	if (!tickStreamActive[bot])
	{
		return;
	}
	if (tickStreamFile[bot] != null)
	{
		delete tickStreamFile[bot];
	}
	if (tickStreamKeyframes[bot] != null)
	{
		delete tickStreamKeyframes[bot];
	}
	if (tickStreamWindow[bot] != null)
	{
		delete tickStreamWindow[bot];
	}
	tickStreamActive[bot] = false;
	tickStreamWindowStart[bot] = 0;
	tickStreamCursor[bot] = 0;
	tickStreamFileAtCursor[bot] = false;
	tickStreamTickCount[bot] = 0;
	tickStreamPayloadStart[bot] = 0;
}

// Decode one tick from current file position into accumulator and append to window.
// Caller must ensure file is positioned correctly and cursor < tickCount.
static bool TickStream_DecodeOne(int bot)
{
	File file = tickStreamFile[bot];
	int deltaFlags;
	if (!file.ReadInt32(deltaFlags))
	{
		return false;
	}
	tickStreamAccum[bot][RPDELTA_DELTAFLAGS] = deltaFlags;
	for (int i = 1; i < RP_V2_TICK_DATA_BLOCKSIZE; i++)
	{
		if (deltaFlags & (1 << i))
		{
			int v;
			if (!file.ReadInt32(v))
			{
				return false;
			}
			tickStreamAccum[bot][i] = v;
		}
	}
	tickStreamWindow[bot].PushArray(tickStreamAccum[bot], sizeof(tickStreamAccum[]));
	tickStreamCursor[bot]++;
	return true;
}

// Find largest keyframe with tickIndex <= target. Returns keyframe array index (>= 0).
static int TickStream_FindKeyframe(int bot, int targetTick)
{
	ArrayList keyframes = tickStreamKeyframes[bot];
	int lo = 0;
	int hi = keyframes.Length - 1;
	int best = 0;
	int entry[2];
	while (lo <= hi)
	{
		int mid = (lo + hi) >> 1;
		keyframes.GetArray(mid, entry, sizeof(entry));
		if (entry[0] <= targetTick)
		{
			best = mid;
			lo = mid + 1;
		}
		else
		{
			hi = mid - 1;
		}
	}
	return best;
}

// Trim the front of the window so it holds at most TICK_WINDOW_MAX_TICKS entries
// and at most TICK_WINDOW_BEHIND_TICKS behind the access tick.
static void TickStream_TrimFront(int bot, int accessTick)
{
	ArrayList window = tickStreamWindow[bot];
	int targetStart = accessTick - TICK_WINDOW_BEHIND_TICKS;
	if (targetStart < 0)
	{
		targetStart = 0;
	}
	// Also enforce hard cap.
	int hardStart = tickStreamWindowStart[bot] + window.Length - TICK_WINDOW_MAX_TICKS;
	if (hardStart > targetStart)
	{
		targetStart = hardStart;
	}
	int dropCount = targetStart - tickStreamWindowStart[bot];
	if (dropCount <= 0)
	{
		return;
	}
	if (dropCount >= window.Length)
	{
		window.Clear();
		tickStreamWindowStart[bot] = targetStart;
		return;
	}
	for (int i = 0; i < dropCount; i++)
	{
		window.Erase(0);
	}
	tickStreamWindowStart[bot] = targetStart;
}

// Ensure tickIdx is materialized in the window. Returns relative index (>= 0) on success or -1 on failure (out of range, file error)
static int TickStream_Materialize(int bot, int tickIdx)
{
	if (tickIdx < 0 || tickIdx >= tickStreamTickCount[bot])
	{
		return -1;
	}

	ArrayList window = tickStreamWindow[bot];
	int rel = tickIdx - tickStreamWindowStart[bot];

	// Already in window?
	if (rel >= 0 && rel < window.Length)
	{
		return rel;
	}

	int cursor = tickStreamCursor[bot];

	bool canExtend = tickStreamFileAtCursor[bot]
		&& tickIdx >= cursor
		&& tickIdx - cursor < TICK_WINDOW_AHEAD_TICKS;
	if (!canExtend)
	{
		// Backward or far jump (or first decode after load): seek to keyframe.
		int kfIdx = TickStream_FindKeyframe(bot, tickIdx);
		int entry[2];
		tickStreamKeyframes[bot].GetArray(kfIdx, entry, sizeof(entry));
		tickStreamFile[bot].Seek(tickStreamPayloadStart[bot] + entry[1], SEEK_SET);
		tickStreamFileAtCursor[bot] = true;
		for (int i = 0; i < RP_V2_TICK_DATA_BLOCKSIZE; i++)
		{
			tickStreamAccum[bot][i] = 0;
		}
		window.Clear();
		tickStreamWindowStart[bot] = entry[0];
		tickStreamCursor[bot] = entry[0];
		cursor = entry[0];
	}

	// Decode forward up to and including tickIdx.
	int decodeUntil = tickIdx + 1;
	if (decodeUntil > tickStreamTickCount[bot])
	{
		decodeUntil = tickStreamTickCount[bot];
	}
	while (tickStreamCursor[bot] < decodeUntil)
	{
		if (!TickStream_DecodeOne(bot))
		{
			LogError("TickStream decode failed at tick %d (target %d).", tickStreamCursor[bot], tickIdx);
			tickStreamFileAtCursor[bot] = false;
			return -1;
		}
	}

	TickStream_TrimFront(bot, tickIdx);
	return tickIdx - tickStreamWindowStart[bot];
}

// =====[ TICK ACCESSOR DISPATCHERS ]=====
//
// These wrap the v1/v2 ArrayList path and the v3 streaming path so the rest
// of playback.sp doesn't need to care which storage mode a bot is in.
// v1 still accesses fields by index via playbackTickData[bot].Get(tick, n) directly (legacy 7-cell layout, never streams).

static int Tick_Length(int bot)
{
	if (tickStreamActive[bot])
	{
		return tickStreamTickCount[bot];
	}
	return playbackTickData[bot] != null ? playbackTickData[bot].Length : 0;
}

static bool Tick_IsLoaded(int bot)
{
	return tickStreamActive[bot] || playbackTickData[bot] != null;
}

static void Tick_Free(int bot)
{
	if (tickStreamActive[bot])
	{
		TickStream_Free(bot);
	}
	if (playbackTickData[bot] != null)
	{
		playbackTickData[bot].Clear();
	}
}

static void Tick_GetArray(int bot, int tickIdx, ReplayTickData out)
{
	if (tickStreamActive[bot])
	{
		int rel = TickStream_Materialize(bot, tickIdx);
		if (rel < 0)
		{
			ReplayTickData blank;
			out = blank;
			return;
		}
		tickStreamWindow[bot].GetArray(rel, out);
		return;
	}
	playbackTickData[bot].GetArray(tickIdx, out);
}

static void PlaybackVersion1(int client, int bot, int &buttons)
{		
	int size = playbackTickData[bot].Length;
	float repOrigin[3], repAngles[3];
	int repButtons, repFlags;
	
	// If first or last frame of the playback
	if (playbackTick[bot] == 0 || playbackTick[bot] == (size - 1))
	{
		// Move the bot and pause them at that tick
		repOrigin[0] = playbackTickData[bot].Get(playbackTick[bot], 0);
		repOrigin[1] = playbackTickData[bot].Get(playbackTick[bot], 1);
		repOrigin[2] = playbackTickData[bot].Get(playbackTick[bot], 2);
		repAngles[0] = playbackTickData[bot].Get(playbackTick[bot], 3);
		repAngles[1] = playbackTickData[bot].Get(playbackTick[bot], 4);
		TeleportEntity(client, repOrigin, repAngles, view_as<float>( { 0.0, 0.0, 0.0 } ));
		
		if (!inBreather[bot])
		{
			// Start the breather period
			inBreather[bot] = true;
			breatherStartTime[bot] = GetEngineTime();
			if (playbackTick[bot] == (size - 1)) 
			{
				GOKZ_EmitSoundToClientSpectators(client, gC_ModeEndSounds[GOKZ_GetCoreOption(client, Option_Mode)], _, "Timer End");
			}
		}
		else if (GetEngineTime() > breatherStartTime[bot] + RP_PLAYBACK_BREATHER_TIME)
		{
			// End the breather period
			inBreather[bot] = false;
			botPlaybackPaused[bot] = false;
			if (playbackTick[bot] == 0)
			{
				GOKZ_EmitSoundToClientSpectators(client, gC_ModeStartSounds[GOKZ_GetCoreOption(client, Option_Mode)], _, "Timer Start");
			}
			// Start the bot if first tick. Clear bot if last tick.
			playbackTick[bot]++;
			if (playbackTick[bot] == size)
			{
				playbackTickData[bot].Clear(); // Clear it all out
				botDataLoaded[bot] = false;
				CancelReplayControlsForBot(bot);
				ServerCommand("bot_kick %s", botName[bot]);
			}
		}
	}
	else
	{
		// Check whether somebody is actually spectating the bot
		int spec;
		for (spec = 1; spec < MAXPLAYERS + 1; spec++)
		{
			if (IsValidClient(spec) && GetObserverTarget(spec) == botClient[bot])
			{
				break;
			}
		}
		if (spec == MAXPLAYERS + 1 && !IsReplayBotControlled(bot, botClient[bot]))
		{
			playbackTickData[bot].Clear();
			botDataLoaded[bot] = false;
			CancelReplayControlsForBot(bot);
			ServerCommand("bot_kick %s", botName[bot]);
			return;
		}
		
		// Load in the next tick
		repOrigin[0] = playbackTickData[bot].Get(playbackTick[bot], 0);
		repOrigin[1] = playbackTickData[bot].Get(playbackTick[bot], 1);
		repOrigin[2] = playbackTickData[bot].Get(playbackTick[bot], 2);
		repAngles[0] = playbackTickData[bot].Get(playbackTick[bot], 3);
		repAngles[1] = playbackTickData[bot].Get(playbackTick[bot], 4);
		repButtons = playbackTickData[bot].Get(playbackTick[bot], 5);
		repFlags = playbackTickData[bot].Get(playbackTick[bot], 6);
		
		// Check if the replay is paused
		if (botPlaybackPaused[bot])
		{
			TeleportEntity(client, repOrigin, repAngles, view_as<float>( { 0.0, 0.0, 0.0 } ));
			return;
		}
		
		// Set velocity to travel from current origin to recorded origin
		float currentOrigin[3], velocity[3];
		Movement_GetOrigin(client, currentOrigin);
		MakeVectorFromPoints(currentOrigin, repOrigin, velocity);
		ScaleVector(velocity, 128.0); // Hard-coded 128 tickrate
		TeleportEntity(client, NULL_VECTOR, repAngles, velocity);

		// We need the velocity directly from the replay to calculate the speeds
		// for the HUD.
		MakeVectorFromPoints(botLastOrigin[bot], repOrigin, velocity);
		ScaleVector(velocity, 128.0); // Hard-coded 128 tickrate
		CopyVector(repOrigin, botLastOrigin[bot]);
		
		botSpeed[bot] = GetVectorHorizontalLength(velocity);
		buttons = repButtons;
		botButtons[bot] = repButtons;

		// Should the bot be ducking?!
		if (repButtons & IN_DUCK || repFlags & FL_DUCKING)
		{
			buttons |= IN_DUCK;
		}
		
		// If the replay file says the bot's on the ground, then fine! Unless you're going too fast...
		// Note that we don't mind if replay file says bot isn't on ground but the bot is.
		if (repFlags & FL_ONGROUND && Movement_GetSpeed(client) < SPEED_NORMAL * 2)
		{
			if (timeInAir[bot] > 0)
			{
				botLandingSpeed[bot] = botSpeed[bot];
				timeInAir[bot] = 0;
				botIsTakeoff[bot] = false;
				botJumped[bot] = false;
				hitBhop[bot] = false;
				hitPerf[bot] = false;
				if (!Movement_GetOnGround(client))
				{
					timeOnGround[bot] = 0;
				}
			}
			
			SetEntityFlags(client, GetEntityFlags(client) | FL_ONGROUND);
			Movement_SetMovetype(client, MOVETYPE_WALK);
			
			timeOnGround[bot]++;
			botTakeoffSpeed[bot] = botSpeed[bot];
		}
		else
		{
			if (timeInAir[bot] == 0)
			{
				botIsTakeoff[bot] = true;
				botJumped[bot] = botButtons[bot] & IN_JUMP > 0;
				hitBhop[bot] = (timeOnGround[bot] <= RP_MAX_BHOP_GROUND_TICKS) && botJumped[bot];
				
				if (botMode[bot] == Mode_SimpleKZ)
				{
					hitPerf[bot] = timeOnGround[bot] < 3 && botJumped[bot];
				}
				else
				{
					hitPerf[bot] = timeOnGround[bot] < 2 && botJumped[bot];
				}
				
				if (hitPerf[bot])
				{
					if (botMode[bot] == Mode_SimpleKZ)
					{
						botTakeoffSpeed[bot] = FloatMin(botLandingSpeed[bot], (0.2 * botLandingSpeed[bot] + 200));
					}
					else if (botMode[bot] == Mode_KZTimer)
					{
						botTakeoffSpeed[bot] = FloatMin(botLandingSpeed[bot], 380.0);
					}
					else
					{
						botTakeoffSpeed[bot] = FloatMin(botLandingSpeed[bot], 286.0);
					}
				}
			}
			else
			{
				botJumped[bot] = false;
				botIsTakeoff[bot] = false;
			}
			
			timeInAir[bot]++;
			Movement_SetMovetype(client, MOVETYPE_NOCLIP);
		}

		playbackTick[bot]++;
	}
}
void PlaybackVersion2(int client, int bot, int &buttons, float vel[3], float angles[3])
{
	int size = Tick_Length(bot);
	ReplayTickData prevTickData;
	ReplayTickData currentTickData;
	
	// If first or last frame of the playback
	if (playbackTick[bot] == 0 || playbackTick[bot] == (size - 1))
	{
		// Move the bot and pause them at that tick
		Tick_GetArray(bot, playbackTick[bot], currentTickData);
		Tick_GetArray(bot, IntMax(playbackTick[bot] - 1, 0), prevTickData);
		TeleportEntity(client, currentTickData.origin, currentTickData.angles, view_as<float>( { 0.0, 0.0, 0.0 } ));
		
		if (!inBreather[bot])
		{
			// Start the breather period
			inBreather[bot] = true;
			breatherStartTime[bot] = GetEngineTime();
		}
		else if (GetEngineTime() > breatherStartTime[bot] + RP_PLAYBACK_BREATHER_TIME)
		{
			// End the breather period
			inBreather[bot] = false;
			botPlaybackPaused[bot] = false;

			// Start the bot if first tick. Clear bot if last tick.
			playbackTick[bot]++;
			if (playbackTick[bot] == size)
			{
				Tick_Free(bot);
				botDataLoaded[bot] = false;
				CancelReplayControlsForBot(bot);
				ServerCommand("bot_kick %s", botName[bot]);
			}
		}
	}
	else
	{
		// Check whether somebody is actually spectating the bot
		int spec;
		for (spec = 1; spec < MAXPLAYERS + 1; spec++)
		{
			if (IsValidClient(spec) && GetObserverTarget(spec) == botClient[bot])
			{
				break;
			}
		}
		if (spec == MAXPLAYERS + 1 && !IsReplayBotControlled(bot, botClient[bot]))
		{
			Tick_Free(bot);
			botDataLoaded[bot] = false;
			CancelReplayControlsForBot(bot);
			ServerCommand("bot_kick %s", botName[bot]);
			return;
		}
		
		// Load in the next tick
		Tick_GetArray(bot, playbackTick[bot], currentTickData);
		Tick_GetArray(bot, IntMax(playbackTick[bot] - 1, 0), prevTickData);
		
		// Check if the replay is paused
		if (botPlaybackPaused[bot])
		{
			TeleportEntity(client, currentTickData.origin, currentTickData.angles, view_as<float>( { 0.0, 0.0, 0.0 } ));
			return;
		}

		// Play timer start/end sound, if necessary. Reset teleports
		if (playbackTick[bot] == preAndPostRunTickCount && botReplayType[bot] == ReplayType_Run)
		{
			GOKZ_EmitSoundToClientSpectators(client, gC_ModeStartSounds[GOKZ_GetCoreOption(client, Option_Mode)], _, "Timer Start");
			botCurrentTeleport[bot] = 0;
		}
		if (playbackTick[bot] == botTimeTicks[bot] + preAndPostRunTickCount && botReplayType[bot] == ReplayType_Run)
		{
			GOKZ_EmitSoundToClientSpectators(client, gC_ModeEndSounds[GOKZ_GetCoreOption(client, Option_Mode)], _, "Timer End");
		}
		// We use the previous position/velocity data to recreate sounds accurately.
		// This might not be necessary as we already did do this in OnPlayerRunCmdPost of last tick,
		// but we do it again just in case the values don't match up somehow (eg. collision with moving objects?)
		TeleportEntity(client, NULL_VECTOR, prevTickData.angles, prevTickData.velocity);
		// TeleportEntity does not set the absolute origin and velocity so we need to do it
		// to prevent inaccurate eye position interpolation.
		SetEntPropVector(client, Prop_Data, "m_vecVelocity", prevTickData.velocity);
		SetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", prevTickData.velocity);
		
		SetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", prevTickData.origin);
		SetEntPropVector(client, Prop_Data, "m_vecOrigin", prevTickData.origin);


		// Set buttons and potential inputs.
		int newButtons;
		if (currentTickData.flags & RP_IN_ATTACK)
		{
			newButtons |= IN_ATTACK;
		}
		if (currentTickData.flags & RP_IN_ATTACK2)
		{
			newButtons |= IN_ATTACK2;
		}
		if (currentTickData.flags & RP_IN_JUMP)
		{
			newButtons |= IN_JUMP;
		}
		if (currentTickData.flags & RP_IN_DUCK)
		{
			newButtons |= IN_DUCK;
		}
		// Few assumptions here because the replay doesn't track them: Player doesn't use +klook or +strafe.
		// If the assumptions are wrong we will just end up with wrong sound prediction, no big deal.
		if (currentTickData.flags & RP_IN_FORWARD)
		{
			newButtons |= IN_FORWARD;
			vel[0] += RP_PLAYER_ACCELSPEED;
		}
		if (currentTickData.flags & RP_IN_BACK)
		{
			newButtons |= IN_BACK;
			vel[0] -= RP_PLAYER_ACCELSPEED;
		}
		if (currentTickData.flags & RP_IN_MOVELEFT)
		{
			newButtons |= IN_MOVELEFT;
			vel[1] -= RP_PLAYER_ACCELSPEED;
		}
		if (currentTickData.flags & RP_IN_MOVERIGHT)
		{
			newButtons |= IN_MOVERIGHT;
			vel[1] += RP_PLAYER_ACCELSPEED;
		}
		if (currentTickData.flags & RP_IN_LEFT)
		{
			newButtons |= IN_LEFT;
		}
		if (currentTickData.flags & RP_IN_RIGHT)
		{
			newButtons |= IN_RIGHT;
		}
		if (currentTickData.flags & RP_IN_RELOAD)
		{
			newButtons |= IN_RELOAD;
		}
		if (currentTickData.flags & RP_IN_SPEED)
		{
			newButtons |= IN_SPEED;
		}
		buttons = newButtons;
		botButtons[bot] = buttons;
		// The angles might be wrong if the player teleports, but this should only affect sound prediction.
		angles = currentTickData.angles;

		// Set the bot's MoveType
		MoveType replayMoveType = view_as<MoveType>(prevTickData.flags & RP_MOVETYPE_MASK);
		botMoveType[bot] = replayMoveType;
		if (replayMoveType == MOVETYPE_WALK)
		{
			Movement_SetMovetype(client, MOVETYPE_WALK);
		}
		else if (replayMoveType == MOVETYPE_LADDER)
		{
			botPaused[bot] = false;
			Movement_SetMovetype(client, MOVETYPE_LADDER);
		}
		else
		{
			Movement_SetMovetype(client, MOVETYPE_NOCLIP);
		}
		// Set some variables
		if (currentTickData.flags & RP_TELEPORT_TICK)
		{
			botJustTeleported[bot] = true;
			botCurrentTeleport[bot]++;
		}

		if (currentTickData.flags & RP_TAKEOFF_TICK)
		{
			hitPerf[bot] = currentTickData.flags & RP_HIT_PERF > 0;
			botIsTakeoff[bot] = true;
			botTakeoffSpeed[bot] = GetVectorHorizontalLength(currentTickData.velocity);
		}

		if ((currentTickData.flags & RP_SECONDARY_EQUIPPED) && !IsCurrentWeaponSecondary(client))
		{
			int item = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
			if (item != -1)
			{
				char name[64];
				GetEntityClassname(item, name, sizeof(name));
				FakeClientCommand(client, "use %s", name);
			}
		}
		else if (!(currentTickData.flags & RP_SECONDARY_EQUIPPED) && IsCurrentWeaponSecondary(client))
		{
			int item = GetPlayerWeaponSlot(client, CS_SLOT_KNIFE);
			if (item != -1)
			{
				char name[64];
				GetEntityClassname(item, name, sizeof(name));
				FakeClientCommand(client, "use %s", name);
			}
		}

		#if defined DEBUG
		if(!botPlaybackPaused[bot])
		{
			PrintToServer("Tick: %d", playbackTick[bot]);
			PrintToServer("X %f \nY %f \nZ %f\nPitch %f\nYaw %f", currentTickData.origin[0], currentTickData.origin[1], currentTickData.origin[2], currentTickData.angles[0], currentTickData.angles[1]);
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_WALK)) PrintToServer("MOVETYPE_WALK");
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_LADDER)) PrintToServer("MOVETYPE_LADDER");
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_NOCLIP)) PrintToServer("MOVETYPE_NOCLIP");
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_NOCLIP)) PrintToServer("MOVETYPE_NONE");

			if(currentTickData.flags & RP_IN_ATTACK) PrintToServer("IN_ATTACK");
			if(currentTickData.flags & RP_IN_ATTACK2) PrintToServer("IN_ATTACK2");
			if(currentTickData.flags & RP_IN_JUMP) PrintToServer("IN_JUMP");
			if(currentTickData.flags & RP_IN_DUCK) PrintToServer("IN_DUCK");
			if(currentTickData.flags & RP_IN_FORWARD) PrintToServer("IN_FORWARD");
			if(currentTickData.flags & RP_IN_BACK) PrintToServer("IN_BACK");
			if(currentTickData.flags & RP_IN_LEFT) PrintToServer("IN_LEFT");
			if(currentTickData.flags & RP_IN_RIGHT) PrintToServer("IN_RIGHT");
			if(currentTickData.flags & RP_IN_MOVELEFT) PrintToServer("IN_MOVELEFT");
			if(currentTickData.flags & RP_IN_MOVERIGHT) PrintToServer("IN_MOVERIGHT");
			if(currentTickData.flags & RP_IN_RELOAD) PrintToServer("IN_RELOAD");
			if(currentTickData.flags & RP_IN_SPEED) PrintToServer("IN_SPEED");
			if(currentTickData.flags & RP_IN_USE) PrintToServer("IN_USE");
			if(currentTickData.flags & RP_IN_BULLRUSH) PrintToServer("IN_BULLRUSH");

			if(currentTickData.flags & RP_FL_ONGROUND) PrintToServer("FL_ONGROUND");
			if(currentTickData.flags & RP_FL_DUCKING ) PrintToServer("FL_DUCKING");
			if(currentTickData.flags & RP_FL_SWIM) PrintToServer("FL_SWIM");
			if(currentTickData.flags & RP_UNDER_WATER) PrintToServer("WATERLEVEL!=0");
			if(currentTickData.flags & RP_TELEPORT_TICK) PrintToServer("TELEPORT");
			if(currentTickData.flags & RP_TAKEOFF_TICK) PrintToServer("TAKEOFF");
			if(currentTickData.flags & RP_HIT_PERF) PrintToServer("PERF");
			if(currentTickData.flags & RP_SECONDARY_EQUIPPED) PrintToServer("SECONDARY_WEAPON_EQUIPPED");
			PrintToServer("==============================================================");
		}
		#endif
	}
}

void PlaybackVersion2Post(int client, int bot)
{
	if (botPlaybackPaused[bot])
	{
		return;
	}
	int size = Tick_Length(bot);
	if (playbackTick[bot] != 0 && playbackTick[bot] != (size - 1))
	{
		ReplayTickData currentTickData;
		ReplayTickData prevTickData;
		Tick_GetArray(bot, playbackTick[bot], currentTickData);
		Tick_GetArray(bot, IntMax(playbackTick[bot] - 1, 0), prevTickData);

		// TeleportEntity does not set the absolute origin and velocity so we need to do it
		// to prevent inaccurate eye position interpolation.
		SetEntPropVector(client, Prop_Data, "m_vecVelocity", currentTickData.velocity);
		SetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", currentTickData.velocity);
		
		SetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", currentTickData.origin);
		SetEntPropVector(client, Prop_Data, "m_vecOrigin", currentTickData.origin);

		SetEntPropFloat(client, Prop_Send, "m_angEyeAngles[0]", currentTickData.angles[0]);
		SetEntPropFloat(client, Prop_Send, "m_angEyeAngles[1]", currentTickData.angles[1]);

		MoveType replayMoveType = view_as<MoveType>(currentTickData.flags & RP_MOVETYPE_MASK);
		botMoveType[bot] = replayMoveType;
		int entityFlags = GetEntityFlags(client);
		if (replayMoveType == MOVETYPE_WALK)
		{
			if (currentTickData.flags & RP_FL_ONGROUND)
			{
				SetEntityFlags(client, entityFlags | FL_ONGROUND);
				botPaused[bot] = false;
				// The bot is on the ground, so there must be a ground entity attributed to the bot.
				int groundEnt = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");
				if (groundEnt == -1 && botJustTeleported[bot])
				{
					SetEntPropFloat(client, Prop_Send, "m_flFallVelocity", 0.0);
					float endPosition[3], mins[3], maxs[3];
					GetEntPropVector(client, Prop_Send, "m_vecMaxs", maxs);
					GetEntPropVector(client, Prop_Send, "m_vecMins", mins);
					endPosition = currentTickData.origin;
					endPosition[2] -= 2.0;
					TR_TraceHullFilter(currentTickData.origin, endPosition, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayers);

					// This should always hit.
					if (TR_DidHit())
					{
						groundEnt = TR_GetEntityIndex();
						SetEntPropEnt(client, Prop_Data, "m_hGroundEntity", groundEnt);
					}
				}
			}
			else
			{
				botJustTeleported[bot] = false;
			}
		}
		
		if (currentTickData.flags & RP_UNDER_WATER)
		{
			SetEntityFlags(client, entityFlags | FL_INWATER);
		}
		if (currentTickData.flags & RP_FL_DUCKING)
		{
			SetEntPropFloat(client, Prop_Send, "m_flDuckAmount", 1.0);
			SetEntProp(client, Prop_Send, "m_bDucking", false);
			SetEntProp(client, Prop_Send, "m_bDucked", true);
			SetEntityFlags(client, FL_DUCKING);
		}

		botSpeed[bot] = GetVectorHorizontalLength(currentTickData.velocity);
		playbackTick[bot]++;
	}
}

// Set the bot client's GOKZ options, clan tag and name based on the loaded replay data
static void SetBotStuff(int bot)
{
	if (!botInGame[bot] || !botDataLoaded[bot])
	{
		return;
	}

	int client = botClient[bot];
	
	// Set its movement options just in case it could negatively affect the playback
	GOKZ_SetCoreOption(client, Option_Mode, botMode[bot]);
	GOKZ_SetCoreOption(client, Option_Style, botStyle[bot]);
	
	// Clan tag and name
	SetBotClanTag(bot);
	SetBotName(bot);

	// Bot takes one tick after being put in server to be able to respawn.
	RequestFrame(RequestFrame_SetBotStuff, GetClientUserId(client));
}

public void RequestFrame_SetBotStuff(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client)
	{
		return;
	}
	int bot;
	for (bot = 0; bot <= RP_MAX_BOTS; bot++)
	{
		if (botClient[bot] == client)
		{
			break;
		}
		else if (bot == RP_MAX_BOTS)
		{
			return;
		}
	}
	// Set the bot's team based on if it's NUB or PRO
	if (botReplayType[bot] == ReplayType_Run 
		&& GOKZ_GetTimeTypeEx(botTeleportsUsed[bot]) == TimeType_Pro)
	{
		GOKZ_JoinTeam(client, CS_TEAM_CT, .forceBroadcast = true);
	}
	else
	{
		GOKZ_JoinTeam(client, CS_TEAM_CT, .forceBroadcast = true);
	}
	// Set bot weapons
	// Always start by removing the pistol and knife
	int currentPistol = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
	if (currentPistol != -1)
	{
		RemovePlayerItem(client, currentPistol);
	}
	
	int currentKnife = GetPlayerWeaponSlot(client, CS_SLOT_KNIFE);
	if (currentKnife != -1)
	{
		RemovePlayerItem(client, currentKnife);
	}

	char weaponName[128];
	// Give the bot the knife stored in the replay
	/*
	if (botKnife[bot] != 0)
	{
		CS_WeaponIDToAlias(CS_ItemDefIndexToID(botKnife[bot]), weaponName, sizeof(weaponName));
		Format(weaponName, sizeof(weaponName), "weapon_%s", weaponName);	
		GivePlayerItem(client, weaponName);
	}
	else
	{
		GivePlayerItem(client, "weapon_knife");
	}
	*/
	// We are currently not doing that, as it would require us to disable the
	// FollowCSGOServerGuidelines failsafe if the bot has a non-standard knife.
	GivePlayerItem(client, "weapon_knife");
	
	// Give the bot the pistol stored in the replay
	if (botWeapon[bot] != -1)
	{
		CS_WeaponIDToAlias(CS_ItemDefIndexToID(botWeapon[bot]), weaponName, sizeof(weaponName));
		Format(weaponName, sizeof(weaponName), "weapon_%s", weaponName);
		GivePlayerItem(client, weaponName);
	}

	botCurrentTeleport[bot] = 0;
}

static void SetBotClanTag(int bot)
{
	char tag[MAX_NAME_LENGTH];

	if (botReplayType[bot] == ReplayType_Run)
	{
		if (botCourse[bot] == 0)
		{
			// KZT PRO
			FormatEx(tag, sizeof(tag), "%s %s", 
				gC_ModeNamesShort[botMode[bot]], gC_TimeTypeNames[GOKZ_GetTimeTypeEx(botTeleportsUsed[bot])]);
		}
		else
		{
			// KZT B2 PRO
			FormatEx(tag, sizeof(tag), "%s B%d %s", 
				gC_ModeNamesShort[botMode[bot]], botCourse[bot], gC_TimeTypeNames[GOKZ_GetTimeTypeEx(botTeleportsUsed[bot])]);
		}
	}
	else if (botReplayType[bot] == ReplayType_Jump)
	{
		// KZT LJ
		FormatEx(tag, sizeof(tag), "%s %s",
			gC_ModeNamesShort[botMode[bot]], gC_JumpTypesShort[botJumpType[bot]]);
	}
	else
	{
		// KZT
		FormatEx(tag, sizeof(tag), "%s", 
			gC_ModeNamesShort[botMode[bot]]);
	}

	CS_SetClientClanTag(botClient[bot], tag);
}

static void SetBotName(int bot)
{
	char name[MAX_NAME_LENGTH];

	if (botReplayType[bot] == ReplayType_Run)
	{
		// Convert to database format and back so the formatting is consistent...
		float time = GOKZ_DB_TimeIntToFloat(GOKZ_DB_TimeFloatToInt(botTime[bot]));

		// DanZay (01:23.45)
		FormatEx(name, sizeof(name), "%s (%s)", 
			botAlias[bot], GOKZ_FormatTime(time));
	}
	else if (botReplayType[bot] == ReplayType_Jump)
	{
		if (botJumpBlockDistance[bot] == 0)
		{
			// DanZay (291.44)
			FormatEx(name, sizeof(name), "%s (%.2f)", 
				botAlias[bot], botJumpDistance[bot]);
		}
		else
		{
			// DanZay (291.44 on 289 block)
			FormatEx(name, sizeof(name), "%s (%.2f on %d block)", 
				botAlias[bot], botJumpDistance[bot], botJumpBlockDistance[bot]);
		}
	}
	else
	{
		// DanZay
		FormatEx(name, sizeof(name), "%s", 
			botAlias[bot]);
	}
	
	gB_HideNameChange = true;
	SetClientName(botClient[bot], name);
}

// Returns the number of bots that are currently replaying
static int GetBotsInUse()
{
	int botsInUse = 0;
	for (int bot; bot < RP_MAX_BOTS; bot++)
	{
		if (botInGame[bot] && botDataLoaded[bot])
		{
			botsInUse++;
		}
	}
	return botsInUse;
}

// Returns a bot that isn't currently replaying, or -1 if no unused bots found
static int GetUnusedBot()
{
	for (int bot = 0; bot < RP_MAX_BOTS; bot++)
	{
		if (!botInGame[bot])
		{
			return bot;
		}
	}
	return -1;
}

static void PlaybackSkipToTick(int bot, int tick)
{
	if (botReplayVersion[bot] == 1)
	{
		// Load in the next tick	
		float repOrigin[3], repAngles[3];
		repOrigin[0] = playbackTickData[bot].Get(tick, 0);
		repOrigin[1] = playbackTickData[bot].Get(tick, 1);
		repOrigin[2] = playbackTickData[bot].Get(tick, 2);
		repAngles[0] = playbackTickData[bot].Get(tick, 3);
		repAngles[1] = playbackTickData[bot].Get(tick, 4);
		
		TeleportEntity(botClient[bot], repOrigin, repAngles, view_as<float>( { 0.0, 0.0, 0.0 } ));
	}
	else if (botReplayVersion[bot] >= 2)
	{
		// Load in the next tick
		ReplayTickData currentTickData;
		Tick_GetArray(bot, tick, currentTickData);

		TeleportEntity(botClient[bot], currentTickData.origin, currentTickData.angles, view_as<float>( { 0.0, 0.0, 0.0 } ));

		int direction = tick < playbackTick[bot] ? -1 : 1;
		for (int i = playbackTick[bot]; i != tick; i += direction)
		{
			Tick_GetArray(bot, i, currentTickData);
			if (currentTickData.flags & RP_TELEPORT_TICK)
			{
				botCurrentTeleport[bot] += direction;
			}
		}

		#if defined DEBUG 
			PrintToServer("X %f \nY %f \nZ %f\nPitch %f\nYaw %f", currentTickData.origin[0], currentTickData.origin[1], currentTickData.origin[2], currentTickData.angles[0], currentTickData.angles[1]);
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_WALK)) PrintToServer("MOVETYPE_WALK");
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_LADDER)) PrintToServer("MOVETYPE_LADDER");
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_NOCLIP)) PrintToServer("MOVETYPE_NOCLIP");
			if(currentTickData.flags & RP_MOVETYPE_MASK == view_as<int>(MOVETYPE_NONE)) PrintToServer("MOVETYPE_NONE");

			if(currentTickData.flags & RP_IN_ATTACK) PrintToServer("IN_ATTACK");
			if(currentTickData.flags & RP_IN_ATTACK2) PrintToServer("IN_ATTACK2");
			if(currentTickData.flags & RP_IN_JUMP) PrintToServer("IN_JUMP");
			if(currentTickData.flags & RP_IN_DUCK) PrintToServer("IN_DUCK");
			if(currentTickData.flags & RP_IN_FORWARD) PrintToServer("IN_FORWARD");
			if(currentTickData.flags & RP_IN_BACK) PrintToServer("IN_BACK");
			if(currentTickData.flags & RP_IN_LEFT) PrintToServer("IN_LEFT");
			if(currentTickData.flags & RP_IN_RIGHT) PrintToServer("IN_RIGHT");
			if(currentTickData.flags & RP_IN_MOVELEFT) PrintToServer("IN_MOVELEFT");
			if(currentTickData.flags & RP_IN_MOVERIGHT) PrintToServer("IN_MOVERIGHT");
			if(currentTickData.flags & RP_IN_RELOAD) PrintToServer("IN_RELOAD");
			if(currentTickData.flags & RP_IN_SPEED) PrintToServer("IN_SPEED");
			if(currentTickData.flags & RP_FL_ONGROUND) PrintToServer("FL_ONGROUND");
			if(currentTickData.flags & RP_FL_DUCKING ) PrintToServer("FL_DUCKING");
			if(currentTickData.flags & RP_FL_SWIM) PrintToServer("FL_SWIM");
			if(currentTickData.flags & RP_UNDER_WATER) PrintToServer("WATERLEVEL!=0");
			if(currentTickData.flags & RP_TELEPORT_TICK) PrintToServer("TELEPORT");
			if(currentTickData.flags & RP_TAKEOFF_TICK) PrintToServer("TAKEOFF");
			if(currentTickData.flags & RP_HIT_PERF) PrintToServer("PERF");
			if(currentTickData.flags & RP_SECONDARY_EQUIPPED) PrintToServer("SECONDARY_WEAPON_EQUIPPED");
			PrintToServer("==============================================================");
		#endif
	}

	Movement_SetMovetype(botClient[bot], MOVETYPE_NOCLIP);
	playbackTick[bot] = tick;
}

static bool IsCurrentWeaponSecondary(int client)
{
	int activeWeaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int secondaryEnt = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
	return activeWeaponEnt == secondaryEnt;
}

static void MakePlayerSpectate(int client, int bot)
{
	GOKZ_JoinTeam(client, CS_TEAM_SPECTATOR);
	SetEntProp(client, Prop_Send, "m_iObserverMode", 4);
	SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", bot);
		
	int clientUserID = GetClientUserId(client);
	DataPack data = new DataPack();
	data.WriteCell(clientUserID);
	data.WriteCell(GetClientUserId(bot));
	CreateTimer(0.1, Timer_UpdateBotName, GetClientUserId(bot));
	EnableReplayControls(client);
}

public Action Timer_UpdateBotName(Handle timer, int botUID)
{
	Event e = CreateEvent("spec_target_updated");
	e.SetInt("userid", botUID);
	e.Fire();
	return Plugin_Continue;
}