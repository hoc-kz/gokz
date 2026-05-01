/*
	Bot replay recording logic and processes.
	
	Records data every time OnPlayerRunCmdPost is called.
	If the player doesn't have their timer running, it keeps track
	of the last 2 minutes of their actions. If a player is banned
	while their timer isn't running, those 2 minutes are saved.
	If the player has their timer running, the recording is done from
	the beginning of the run. If the player can no longer beat their PB,
	then the recording goes back to only keeping track of the last
	two minutes. Upon beating the server record, a binary file will be 
	written with a 'header' containing information about the run,
	followed by the recorded tick data from OnPlayerRunCmdPost.
*/

static float tickrate;
static int preAndPostRunTickCount;
static int maxCheaterReplayTicks;
static int recordingIndex[MAXPLAYERS + 1];
static float playerSensitivity[MAXPLAYERS + 1];
static float playerMYaw[MAXPLAYERS + 1];
static bool isTeleportTick[MAXPLAYERS + 1];
static bool isRecordingRun[MAXPLAYERS + 1];
static bool recordingPaused[MAXPLAYERS + 1];
static bool postRunRecording[MAXPLAYERS + 1];
static ArrayList recordedRecentData[MAXPLAYERS + 1];
static ArrayList recordedRecentNetStats[MAXPLAYERS + 1];
static Handle runningRunBreatherTimer[MAXPLAYERS + 1];
static ArrayList runningJumpstatTimers[MAXPLAYERS + 1];

// Run/post-run tick streams are written to per-client temp files instead of
// in-memory ArrayLists. Two slots per client (ping-pong) so a new run can begin
// recording while the previous run's post-run breather is still flushing.
#define REC_NUM_SLOTS 2
static File recSlotFile[MAXPLAYERS + 1][REC_NUM_SLOTS];
static int recRecordCount[MAXPLAYERS + 1][REC_NUM_SLOTS];
static int runSlot[MAXPLAYERS + 1];
static int postRunSlot[MAXPLAYERS + 1];

// =====[ EVENTS ]=====

void OnMapStart_Recording()
{
	CreateReplaysDirectory();
	CleanReplaysTempDir();
	tickrate = 1/GetTickInterval();
	preAndPostRunTickCount = RoundToZero(RP_PLAYBACK_BREATHER_TIME * tickrate);
	maxCheaterReplayTicks = RoundToCeil(RP_MAX_CHEATER_REPLAY_LENGTH * tickrate);
}

void OnClientPutInServer_Recording(int client)
{
	ClearClientRecordingState(client);
}

void OnClientAuthorized_Recording(int client)
{
	// Apparently the client isn't valid yet here, so we can't check for that!
	if(!IsFakeClient(client))
	{
		// Create directory path for player if not exists
		char replayPath[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, replayPath, sizeof(replayPath), "%s/%d", RP_DIRECTORY_JUMPS, GetSteamAccountID(client));
		if (!DirExists(replayPath))
		{
			CreateDirectory(replayPath, 511);
		}
		BuildPath(Path_SM, replayPath, sizeof(replayPath), "%s/%d/%s", RP_DIRECTORY_JUMPS, GetSteamAccountID(client), RP_DIRECTORY_BLOCKJUMPS);
		if (!DirExists(replayPath))
		{
			CreateDirectory(replayPath, 511);
		}
	}
}

void OnClientDisconnect_Recording(int client)
{
	// Stop exceptions if OnClientPutInServer was never ran for this client id.
	// As long as the arrays aren't null we'll be fine.
	if (runningJumpstatTimers[client] == null)
	{
		return;
	}

	// Trigger all timers early
	if(!IsFakeClient(client))
	{
		if (runningRunBreatherTimer[client] != INVALID_HANDLE)
		{
			TriggerTimer(runningRunBreatherTimer[client], false);
		}

		// We have to clone the array because the timer callback removes the timer
		// from the array we're running over, and doing weird tricks is scary.
		ArrayList timers = runningJumpstatTimers[client].Clone();
		for (int i = 0; i < timers.Length; i++)
		{
			Handle timer = timers.Get(i);
			TriggerTimer(timer, false);
		}
		delete timers;
	}

	ClearClientRecordingState(client);

	for (int slot = 0; slot < REC_NUM_SLOTS; slot++)
	{
		RecCloseSlot(client, slot);
	}
}

void OnPlayerRunCmdPost_Recording(int client, int buttons, int tickCount, const float vel[3], const int mouse[2])
{
	if (!IsValidClient(client) || IsFakeClient(client) || !IsPlayerAlive(client) || recordingPaused[client])
	{
		return;
	}

	ReplayTickData tickData;

	Movement_GetOrigin(client, tickData.origin);

	tickData.mouse = mouse;
	tickData.vel = vel;
	Movement_GetVelocity(client, tickData.velocity);
	Movement_GetEyeAngles(client, tickData.angles);
	tickData.flags = EncodePlayerFlags(client, buttons, tickCount);
	tickData.packetsPerSecond = GetClientAvgPackets(client, NetFlow_Incoming);
	tickData.laggedMovementValue = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
	tickData.buttonsForced = GetEntProp(client, Prop_Data, "m_afButtonForced");

	ReplayNetStats netStats;
	CaptureNetStats(client, netStats);

	// HACK: Reset teleport tick marker. Too bad!
	if (isTeleportTick[client])
	{
		isTeleportTick[client] = false;
	}
	
	if (isRecordingRun[client])
	{
		int slot = runSlot[client];
		if (recRecordCount[client][slot] < RP_MAX_DURATION)
		{
			RecAppendRecord(client, slot, tickData, netStats);
		}
	}
	if (postRunRecording[client])
	{
		int slot = postRunSlot[client];
		if (recRecordCount[client][slot] < RP_MAX_DURATION)
		{
			RecAppendRecord(client, slot, tickData, netStats);
		}
	}
	
	int tick = recordingIndex[client];
	if (recordedRecentData[client].Length < maxCheaterReplayTicks)
	{
		recordedRecentData[client].Resize(recordedRecentData[client].Length + 1);
		recordedRecentNetStats[client].Resize(recordedRecentData[client].Length);
		recordingIndex[client] = recordingIndex[client] + 1 == maxCheaterReplayTicks ? 0 : recordingIndex[client] + 1;
	}
	else
	{
		recordingIndex[client] = RecordingIndexAdd(client, 1);
	}

	recordedRecentData[client].SetArray(tick, tickData);
	recordedRecentNetStats[client].SetArray(tick, netStats);
}

Action GOKZ_OnTimerStart_Recording(int client)
{
	// Hack to fix an exception when starting the timer on the very
	// first tick after loading the plugin.
	if (recordedRecentData[client].Length == 0)
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

void GOKZ_OnTimerStart_Post_Recording(int client)
{
	isRecordingRun[client] = true;
	StartRunRecording(client);
}

void GOKZ_OnTimerEnd_Recording(int client, int course, float time, int teleportsUsed)
{
	if (!isRecordingRun[client])
	{
		return;
	}

	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	int style = GOKZ_GetCoreOption(client, Option_Style);

	char guid[GOKZ_DB_TIME_GUID_MAX];
	GOKZ_DB_GetRunGUID(client, guid);

	DataPack data = new DataPack();
	data.WriteCell(GetClientUserId(client));
	data.WriteCell(mode);
	data.WriteCell(style);
	data.WriteCell(course);
	data.WriteFloat(time);
	data.WriteCell(teleportsUsed);
	data.WriteString(guid);
	// The previous run breather still did not finish, end it now or
	// we will start overwriting the data.
	if (runningRunBreatherTimer[client] != INVALID_HANDLE)
	{
		TriggerTimer(runningRunBreatherTimer[client], false);
	}

	isRecordingRun[client] = false;
	postRunRecording[client] = true;

	// Hand the slot we were appending to off to post-run,
	//  then truncate the other slot so the next run can begin recording immediately.
	postRunSlot[client] = runSlot[client];
	runSlot[client] = (runSlot[client] + 1) % REC_NUM_SLOTS;
	RecTruncateSlot(client, runSlot[client]);

	runningRunBreatherTimer[client] = CreateTimer(RP_PLAYBACK_BREATHER_TIME, Timer_EndRecording, data);
	if (runningRunBreatherTimer[client] == INVALID_HANDLE)
	{
		LogError("Could not create a timer so can't end the run replay recording");
	}
}

public Action Timer_EndRecording(Handle timer, DataPack data)
{
	char guid[GOKZ_DB_TIME_GUID_MAX];

	data.Reset();
	int client = GetClientOfUserId(data.ReadCell());
	int mode = data.ReadCell();
	int style = data.ReadCell();
	int course = data.ReadCell();
	float time = data.ReadFloat();
	int teleportsUsed = data.ReadCell();
	data.ReadString(guid, sizeof(guid));
	delete data;

	// The client left after the run was done but before the post-run
	// breather had the chance to finish. This should not happen, as we
	// trigger all running timers on disconnect.
	if (!IsValidClient(client))
	{
		return Plugin_Stop;
	}

	runningRunBreatherTimer[client] = INVALID_HANDLE;
	postRunRecording[client] = false;
	
	SaveRecordingOfRun(client, mode, style, course, time, teleportsUsed, guid);

	return Plugin_Stop;
}

void GOKZ_OnPause_Recording(int client)
{
	PauseRecording(client);
}

void GOKZ_OnResume_Recording(int client)
{
	ResumeRecording(client);
}

void GOKZ_OnTimerStopped_Recording(int client)
{
	isRecordingRun[client] = false;
}

void GOKZ_OnCountedTeleport_Recording(int client)
{
	isTeleportTick[client] = true;
}

public void GOKZ_LR_OnPBMissed(int client, float pbTime, int course, int mode, int style, int recordType)
{
	// If missed PRO record or both records, then can no longer beat PB
	if (recordType == RecordType_NubAndPro || recordType == RecordType_Pro)
	{
		isRecordingRun[client] = false;
	}

	// If on a NUB run and missed NUB record, then can no longer beat PB
	// Otherwise wait to see if they teleport before stopping the recording
	if (recordType == RecordType_Nub)
	{
		if (GOKZ_GetTeleportCount(client) > 0)
		{
			isRecordingRun[client] = false;
		}
	}
}

void GOKZ_AC_OnPlayerSuspected_Recording(int client, ACReason reason)
{
	SaveRecordingOfCheater(client, reason);
}

void GOKZ_DB_OnJumpstatPB_Recording(int client, int jumptype, int mode, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
	// Do NOT call GOKZ_GetCoreOption here, this is many ticks after the PB actually happened.
	int style = Style_Normal;

	DataPack data = new DataPack();
	data.WriteCell(GetClientUserId(client));
	data.WriteCell(mode);
	data.WriteCell(style);
	data.WriteCell(jumptype);
	data.WriteFloat(distance);
	data.WriteCell(block);
	data.WriteCell(strafes);
	data.WriteFloat(sync);
	data.WriteFloat(pre);
	data.WriteFloat(max);
	data.WriteCell(airtime);

	Handle timer = CreateTimer(RP_PLAYBACK_BREATHER_TIME, SaveJump, data);
	if (timer != INVALID_HANDLE)
	{
		runningJumpstatTimers[client].Push(timer);
	}
	else
	{
		LogError("Could not create a timer so can't save jumpstat pb replay");
	}
}

public Action SaveJump(Handle timer, DataPack data)
{
	data.Reset();
	int client = GetClientOfUserId(data.ReadCell());
	int mode = data.ReadCell();
	int style = data.ReadCell();
	int jumptype = data.ReadCell();
	float distance = data.ReadFloat();
	int block = data.ReadCell();
	int strafes = data.ReadCell();
	float sync = data.ReadFloat();
	float pre = data.ReadFloat();
	float max = data.ReadFloat();
	int airtime = data.ReadCell();
	delete data;

	// The client left after the jump was done but before the post-jump
	// breather had the chance to finish. This should not happen, as we
	// trigger all running timers on disconnect.
	if (!IsValidClient(client))
	{
		return Plugin_Stop;
	}

	RemoveFromRunningTimers(client, timer);

	SaveRecordingOfJump(client, mode, style, jumptype, distance, block, strafes, sync, pre, max, airtime);
	return Plugin_Stop;
}



// =====[ PRIVATE ]=====

static void ClearClientRecordingState(int client)
{
	recordingIndex[client] = 0;
	playerSensitivity[client] = -1.0;
	playerMYaw[client] = -1.0;
	isTeleportTick[client] = false;
	isRecordingRun[client] = false;
	recordingPaused[client] = false;
	postRunRecording[client] = false;
	runningRunBreatherTimer[client] = INVALID_HANDLE;

	if (recordedRecentData[client] == null)
		recordedRecentData[client] = new ArrayList(sizeof(ReplayTickData));

	if (recordedRecentNetStats[client] == null)
		recordedRecentNetStats[client] = new ArrayList(sizeof(ReplayNetStats));

	if (runningJumpstatTimers[client] == null)
		runningJumpstatTimers[client] = new ArrayList();

	recordedRecentData[client].Clear();
	recordedRecentNetStats[client].Clear();
	runningJumpstatTimers[client].Clear();

	runSlot[client] = 0;
	postRunSlot[client] = 1;
	for (int slot = 0; slot < REC_NUM_SLOTS; slot++)
	{
		recRecordCount[client][slot] = 0;
	}
	if (!IsClientConnected(client) || IsFakeClient(client))
	{
		return;
	}
	for (int slot = 0; slot < REC_NUM_SLOTS; slot++)
	{
		RecTruncateSlot(client, slot);
	}
}

static void StartRunRecording(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	QueryClientConVar(client, "sensitivity", SensitivityCheck, client);
	QueryClientConVar(client, "m_yaw", MYAWCheck, client);
	
	DiscardRecording(client);
	ResumeRecording(client);
	
	// Pre-fill the run slot with the pre-run breather window from the rolling
	// recent-data buffers (ticks and netstats are kept in lockstep).
	int slot = runSlot[client];
	int index;
	if (recordedRecentData[client].Length < preAndPostRunTickCount)
	{
		index = recordingIndex[client] - preAndPostRunTickCount;
	}
	else
	{
		index = RecordingIndexAdd(client, -preAndPostRunTickCount);
	}
	for (int i = 0; i < preAndPostRunTickCount; i++)
	{
		ReplayTickData tickData;
		ReplayNetStats netStats;
		int readIndex = index < 0 ? 0 : index;
		recordedRecentData[client].GetArray(readIndex, tickData);
		recordedRecentNetStats[client].GetArray(readIndex, netStats);
		RecAppendRecord(client, slot, tickData, netStats);
		if (index < 0)
		{
			index += 1;
		}
		else
		{
			index = RecordingIndexAdd(client, -preAndPostRunTickCount + i + 1);
		}
	}
}

static void DiscardRecording(int client)
{
	RecTruncateSlot(client, runSlot[client]);
}

static void PauseRecording(int client)
{
	recordingPaused[client] = true;
}

static void ResumeRecording(int client)
{
	recordingPaused[client] = false;
}

static bool SaveRecordingOfRun(int client, int mode, int style, int course, float time, int teleportsUsed, const char[] guid)
{
	int slot = postRunSlot[client];

	// Create and fill General Header
	GeneralReplayHeader generalHeader;
	FillGeneralHeader(generalHeader, client, ReplayType_Run, mode, style, recRecordCount[client][slot]);

	// Create and fill Run Header
	RunReplayHeader runHeader;
	runHeader.time = time;
	runHeader.course = course;
	runHeader.teleportsUsed = teleportsUsed;

	// Build path and create/overwrite associated file
	char replayPath[PLATFORM_MAX_PATH];
	GOKZ_RP_FormatRunReplayPath(replayPath, sizeof(replayPath), guid);
	if (FileExists(replayPath)) // This is the coldest branch in the history of cold branches.
	{
		DeleteFile(replayPath);
	}

	File file = OpenFile(replayPath, "wb");
	if (file == null)
	{
		LogError("Failed to create/open replay file to write to: \"%s\".", replayPath);
		return false;
	}

	WriteGeneralHeader(file, generalHeader);

	// Write run header
	file.WriteInt32(view_as<int>(runHeader.time));
	file.WriteInt8(runHeader.course);
	file.WriteInt32(runHeader.teleportsUsed);

	WriteSectionTicks(file, client, ReplayType_Run);
	WriteSectionWeapons(file, client);
	WriteSectionNetStats(file, client, ReplayType_Run);
	WriteSectionEnd(file);

	delete file;

	RecTruncateSlot(client, slot);

	LogMessage("Saved run replay '%s' (player: %d, map: %s, course: %d, time: %f, teleports: %d)",
		guid, GetSteamAccountID(client), generalHeader.mapName, course, time, teleportsUsed);

	return true;
}

static bool SaveRecordingOfCheater(int client, ACReason reason)
{
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	int style = GOKZ_GetCoreOption(client, Option_Style);

	// Create and fill general header
	GeneralReplayHeader generalHeader;
	FillGeneralHeader(generalHeader, client, ReplayType_Cheater, mode, style, recordedRecentData[client].Length);

	// Create and fill cheater header
	CheaterReplayHeader cheaterHeader;
	cheaterHeader.ACReason = reason;

	//Build path and create/overwrite associated file
	char replayPath[PLATFORM_MAX_PATH];
	FormatCheaterReplayPath(replayPath, sizeof(replayPath), client, generalHeader.mode, generalHeader.style);

	File file = OpenFile(replayPath, "wb");
	if (file == null)
	{
		LogError("Failed to create/open replay file to write to: \"%s\".", replayPath);
		return false;
	}

	WriteGeneralHeader(file, generalHeader);
	file.WriteInt8(view_as<int>(cheaterHeader.ACReason));
	WriteSectionTicks(file, client, ReplayType_Cheater);
	WriteSectionWeapons(file, client);
	WriteSectionNetStats(file, client, ReplayType_Cheater);
	WriteSectionEnd(file);

	delete file;

	return true;
}

static bool SaveRecordingOfJump(int client, int mode, int style, int jumptype, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
	// Just cause I know how buggy jumpstats can be
	int airtimeTicks = RoundToNearest((float(airtime) / GOKZ_DB_JS_AIRTIME_PRECISION) * tickrate);
	if (airtimeTicks + 2 * preAndPostRunTickCount >= maxCheaterReplayTicks)
	{
		LogError("WARNING: Invalid airtime (this is probably a bugged jump, please report it!).");
		return false;
	}
	
	// Create and fill general header
	GeneralReplayHeader generalHeader;
	FillGeneralHeader(generalHeader, client, ReplayType_Jump, mode, style, 2 * preAndPostRunTickCount + airtimeTicks);

	// Create and fill jump header
	JumpReplayHeader jumpHeader;
	FillJumpHeader(jumpHeader, jumptype, distance, block, strafes, sync, pre, max, airtime);

	// Make sure the client is authenticated
	if (GetSteamAccountID(client) == 0)
	{
		LogError("Failed to save jump, client is not authenticated.");
		return false;
	}

	// Build path and create/overwrite associated file
	char replayPath[PLATFORM_MAX_PATH];
	if (block > 0)
	{
		FormatBlockJumpReplayPath(replayPath, sizeof(replayPath), client, block, jumpHeader.jumpType, generalHeader.mode, generalHeader.style);
	}
	else
	{
		FormatJumpReplayPath(replayPath, sizeof(replayPath), client, jumpHeader.jumpType, generalHeader.mode, generalHeader.style);
	}

	File file = OpenFile(replayPath, "wb");
	if (file == null)
	{
		LogError("Failed to create/open replay file to write to: \"%s\".", replayPath);
		delete file;
		return false;
	}

	WriteGeneralHeader(file, generalHeader);
	WriteJumpHeader(file, jumpHeader);
	WriteSectionTicks(file, client, ReplayType_Jump, airtimeTicks);
	WriteSectionWeapons(file, client);
	WriteSectionNetStats(file, client, ReplayType_Jump, airtimeTicks);
	WriteSectionEnd(file);

	delete file;

	return true;
}

static void FillGeneralHeader(GeneralReplayHeader generalHeader, int client, int replayType, int mode, int style, int tickCount)
{
	// Fill general header
	generalHeader.magicNumber = RP_MAGIC_NUMBER;
	generalHeader.formatVersion = RP_FORMAT_VERSION;
	generalHeader.replayType = replayType;
	generalHeader.gokzVersion = GOKZ_VERSION;
	generalHeader.mapName = gC_CurrentMap;
	generalHeader.mapFileSize = gI_CurrentMapFileSize;
	generalHeader.serverIP = FindConVar("hostip").IntValue;
	generalHeader.timestamp = GetTime();
	GetClientName(client, generalHeader.playerAlias, sizeof(GeneralReplayHeader::playerAlias));
	generalHeader.playerSteamID = GetSteamAccountID(client);
	generalHeader.mode = mode;
	generalHeader.style = style;
	generalHeader.playerSensitivity = playerSensitivity[client];
	generalHeader.playerMYaw = playerMYaw[client];
	generalHeader.tickrate = tickrate;
	generalHeader.tickCount = tickCount;
	generalHeader.equippedWeapon = GetPlayerWeaponSlotDefIndex(client, CS_SLOT_SECONDARY);
	generalHeader.equippedKnife = GetPlayerWeaponSlotDefIndex(client, CS_SLOT_KNIFE);
}

static void FillJumpHeader(JumpReplayHeader jumpHeader, int jumptype, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
	jumpHeader.jumpType = jumptype;
	jumpHeader.distance = distance;
	jumpHeader.blockDistance = block;
	jumpHeader.strafeCount = strafes;
	jumpHeader.sync = sync;
	jumpHeader.pre = pre;
	jumpHeader.max = max;
	jumpHeader.airtime = airtime;
}

static void WriteGeneralHeader(File file, GeneralReplayHeader generalHeader)
{
	file.WriteInt32(generalHeader.magicNumber);
	file.WriteInt8(generalHeader.formatVersion);
	file.WriteInt8(generalHeader.replayType);
	file.WriteInt8(strlen(generalHeader.gokzVersion));
	file.WriteString(generalHeader.gokzVersion, false);
	file.WriteInt8(strlen(generalHeader.mapName));
	file.WriteString(generalHeader.mapName, false);
	file.WriteInt32(generalHeader.mapFileSize);
	file.WriteInt32(generalHeader.serverIP);
	file.WriteInt32(generalHeader.timestamp);
	file.WriteInt8(strlen(generalHeader.playerAlias));
	file.WriteString(generalHeader.playerAlias, false);
	file.WriteInt32(generalHeader.playerSteamID);
	file.WriteInt8(generalHeader.mode);
	file.WriteInt8(generalHeader.style);
	file.WriteInt32(view_as<int>(generalHeader.playerSensitivity));
	file.WriteInt32(view_as<int>(generalHeader.playerMYaw));
	file.WriteInt32(view_as<int>(generalHeader.tickrate));
	file.WriteInt32(generalHeader.tickCount);
	file.WriteInt32(generalHeader.equippedWeapon);
	file.WriteInt32(generalHeader.equippedKnife);
}

static void WriteJumpHeader(File file, JumpReplayHeader jumpHeader)
{
	file.WriteInt8(jumpHeader.jumpType);
	file.WriteInt32(view_as<int>(jumpHeader.distance));
	file.WriteInt32(jumpHeader.blockDistance);
	file.WriteInt8(jumpHeader.strafeCount);
	file.WriteInt32(view_as<int>(jumpHeader.sync));
	file.WriteInt32(view_as<int>(jumpHeader.pre));
	file.WriteInt32(view_as<int>(jumpHeader.max));
	file.WriteInt32((jumpHeader.airtime));
}

static void WriteSectionTicks(File file, int client, int replayType, int airtime = 0)
{
	file.WriteInt32(RP_SECTION_TICKS);
	file.WriteInt8(RP_CODEC_RAW);

	int lenPos = file.Position;
	file.WriteInt32(0); // length placeholder
	file.WriteInt32(0); // uncompressedLength placeholder

	int payloadStart = file.Position;
	WriteTickData(file, client, replayType, airtime);
	int payloadEnd = file.Position;

	int len = payloadEnd - payloadStart;
	file.Seek(lenPos, SEEK_SET);
	file.WriteInt32(len);
	file.WriteInt32(len); // uncompressedLength == length for raw codec
	file.Seek(payloadEnd, SEEK_SET);
}

static void WriteSectionEnd(File file)
{
	file.WriteInt32(RP_SECTION_END);
}

// =====[ NETSTATS SECTION ]=====

static void CaptureNetStats(int client, ReplayNetStats netStats)
{
	float latency = GetClientLatency(client, NetFlow_Both);
	int latencyMs = RoundToNearest(latency * 1000.0);
	if (latencyMs < 0) latencyMs = 0;
	if (latencyMs > 32767) latencyMs = 32767;
	netStats.latencyMs = latencyMs;

	netStats.lossInX10k  = ScaleLossOrChoke(GetClientAvgLoss(client,  NetFlow_Incoming));
	netStats.lossOutX10k = ScaleLossOrChoke(GetClientAvgLoss(client,  NetFlow_Outgoing));
	netStats.chokeInX10k  = ScaleLossOrChoke(GetClientAvgChoke(client, NetFlow_Incoming));
	netStats.chokeOutX10k = ScaleLossOrChoke(GetClientAvgChoke(client, NetFlow_Outgoing));
}

static int ScaleLossOrChoke(float value)
{
	int scaled = RoundToNearest(value * 10000.0);
	if (scaled < 0) return 0;
	if (scaled > 10000) return 10000;
	return scaled;
}

static void WriteSectionNetStats(File file, int client, int replayType, int airtime = 0)
{
	file.WriteInt32(RP_SECTION_NETSTATS);
	file.WriteInt8(RP_CODEC_RAW);

	int lenPos = file.Position;
	file.WriteInt32(0); // length placeholder
	file.WriteInt32(0); // uncompressedLength placeholder

	int payloadStart = file.Position;
	WriteCache_SetFile(file);
	WriteNetStatsPayload(client, replayType, airtime);
	WriteCache_Flush();
	int payloadEnd = file.Position;

	int len = payloadEnd - payloadStart;
	file.Seek(lenPos, SEEK_SET);
	file.WriteInt32(len);
	file.WriteInt32(len);
	file.Seek(payloadEnd, SEEK_SET);
}

static void WriteNetStatsPayload(int client, int replayType, int airtime)
{
	ReplayNetStats netStats;

	switch (replayType)
	{
		case ReplayType_Run:
		{
			int slot = postRunSlot[client];
			int n = recRecordCount[client][slot];
			WriteCache_WriteInt32(n);
			if (n > 0)
			{
				File sf = recSlotFile[client][slot];
				sf.Flush();
				sf.Seek(0, SEEK_SET);
				any record[RP_V2_TICK_DATA_BLOCKSIZE + sizeof(ReplayNetStats)];
				for (int i = 0; i < n; i++)
				{
					sf.Read(record, sizeof(record), 4);
					netStats.latencyMs    = record[RP_V2_TICK_DATA_BLOCKSIZE + 0];
					netStats.lossInX10k   = record[RP_V2_TICK_DATA_BLOCKSIZE + 1];
					netStats.lossOutX10k  = record[RP_V2_TICK_DATA_BLOCKSIZE + 2];
					netStats.chokeInX10k  = record[RP_V2_TICK_DATA_BLOCKSIZE + 3];
					netStats.chokeOutX10k = record[RP_V2_TICK_DATA_BLOCKSIZE + 4];
					WriteNetStatsEntry(netStats);
				}
			}
		}
		case ReplayType_Cheater:
		{
			int n = recordedRecentNetStats[client].Length;
			WriteCache_WriteInt32(n);
			for (int i = 0; i < n; i++)
			{
				int rollingI = RecordingIndexAdd(client, i);
				recordedRecentNetStats[client].GetArray(rollingI, netStats);
				WriteNetStatsEntry(netStats);
			}
		}
		case ReplayType_Jump:
		{
			int n = 2 * preAndPostRunTickCount + airtime;
			WriteCache_WriteInt32(n);
			for (int i = 0; i < n; i++)
			{
				int rollingI = RecordingIndexAdd(client, i - n);
				recordedRecentNetStats[client].GetArray(rollingI, netStats);
				WriteNetStatsEntry(netStats);
			}
		}
	}
}

static void WriteNetStatsEntry(ReplayNetStats netStats)
{
	WriteCache_WriteInt16(netStats.latencyMs);
	WriteCache_WriteInt16(netStats.lossInX10k);
	WriteCache_WriteInt16(netStats.lossOutX10k);
	WriteCache_WriteInt16(netStats.chokeInX10k);
	WriteCache_WriteInt16(netStats.chokeOutX10k);
}

// =====[ WEAPONS SECTION ]=====

static void WriteSectionWeapons(File file, int client)
{
	ArrayList weapons = new ArrayList(sizeof(ReplayWeaponEntry));
	CaptureWeapons(client, weapons);

	file.WriteInt32(RP_SECTION_WEAPONS);
	file.WriteInt8(RP_CODEC_RAW);

	int lenPos = file.Position;
	file.WriteInt32(0);
	file.WriteInt32(0);

	int payloadStart = file.Position;
	WriteCache_SetFile(file);
	WriteWeaponsPayload(weapons);
	WriteCache_Flush();
	int payloadEnd = file.Position;

	int len = payloadEnd - payloadStart;
	file.Seek(lenPos, SEEK_SET);
	file.WriteInt32(len);
	file.WriteInt32(len);
	file.Seek(payloadEnd, SEEK_SET);

	delete weapons;
}

static void CaptureWeapons(int client, ArrayList weapons)
{
	int slots[] = { CS_SLOT_PRIMARY, CS_SLOT_SECONDARY, CS_SLOT_KNIFE };
	for (int i = 0; i < sizeof(slots); i++)
	{
		int ent = GetPlayerWeaponSlot(client, slots[i]);
		if (ent == -1)
		{
			continue;
		}

		ReplayWeaponEntry entry;
		entry.slot = slots[i];
		entry.defIndex = GetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex");
		entry.paintKit = GetEntProp(ent, Prop_Send, "m_nFallbackPaintKit");
		entry.seed     = GetEntProp(ent, Prop_Send, "m_nFallbackSeed");
		entry.wear     = GetEntPropFloat(ent, Prop_Send, "m_flFallbackWear");
		entry.statTrak = HasEntProp(ent, Prop_Send, "m_nFallbackStatTrak")
			? GetEntProp(ent, Prop_Send, "m_nFallbackStatTrak")
			: -1;

		if (HasEntProp(ent, Prop_Send, "m_szCustomName"))
		{
			GetEntPropString(ent, Prop_Send, "m_szCustomName", entry.nametag, sizeof(ReplayWeaponEntry::nametag));
		}

		for (int s = 0; s < RP_MAX_WEAPON_STICKERS; s++)
		{
			entry.stickerKit[s] = 0;
			entry.stickerWear[s] = 0.0;
			entry.stickerScale[s] = 0.0;
			entry.stickerRotation[s] = 0.0;
		}

		weapons.PushArray(entry);
	}
}

static void WriteWeaponsPayload(ArrayList weapons)
{
	WriteCache_WriteInt8(weapons.Length);

	ReplayWeaponEntry entry;
	for (int i = 0; i < weapons.Length; i++)
	{
		weapons.GetArray(i, entry);

		WriteCache_WriteInt8(entry.slot);
		WriteCache_WriteInt32(entry.defIndex);
		WriteCache_WriteInt32(entry.paintKit);
		WriteCache_WriteInt32(entry.seed);
		WriteCache_WriteInt32(view_as<int>(entry.wear));
		WriteCache_WriteInt32(entry.statTrak);

		int nameLen = strlen(entry.nametag);
		WriteCache_WriteInt8(nameLen);
		if (nameLen > 0)
		{
			WriteCache_WriteString(entry.nametag, nameLen);
		}

		for (int s = 0; s < RP_MAX_WEAPON_STICKERS; s++)
		{
			WriteCache_WriteInt32(entry.stickerKit[s]);
			WriteCache_WriteInt32(view_as<int>(entry.stickerWear[s]));
			WriteCache_WriteInt32(view_as<int>(entry.stickerScale[s]));
			WriteCache_WriteInt32(view_as<int>(entry.stickerRotation[s]));
		}
	}
}

static void WriteTickData(File file, int client, int replayType, int airtime = 0)
{
	// Do NOT use file.Write functions here or write cache will write out of order!!!
	WriteCache_SetFile(file);

	// Keyframes (every Nth tick) force isFirstTick=true so the playback decoder can resync without replaying tick 0..N-1.
	// We append a (tickIndex, payloadOffset) trailer at the end of the section so loaders can build the index in one pass.
	ArrayList keyframes = new ArrayList(2);

	any tickData[2][RP_V2_TICK_DATA_BLOCKSIZE];
	int currentTickData = 0;
	switch(replayType)
	{
		case ReplayType_Run:
		{
			int slot = postRunSlot[client];
			int replayLength = recRecordCount[client][slot];
			File sf = recSlotFile[client][slot];
			if (replayLength > 0)
			{
				sf.Flush();
				sf.Seek(0, SEEK_SET);
			}
			any record[RP_V2_TICK_DATA_BLOCKSIZE + sizeof(ReplayNetStats)];
			for (int i = 0; i < replayLength; i++)
			{
				bool isKeyframe = (i % RP_TICKS_KEYFRAME_INTERVAL) == 0;
				if (isKeyframe)
				{
					int entry[2];
					entry[0] = i;
					entry[1] = WriteCache_BytesWritten();
					keyframes.PushArray(entry, sizeof(entry));
				}
				sf.Read(record, sizeof(record), 4);
				for (int j = 0; j < RP_V2_TICK_DATA_BLOCKSIZE; j++)
				{
					tickData[currentTickData][j] = record[j];
				}
				WriteTickDataThroughWriteCache(isKeyframe, tickData[currentTickData], tickData[currentTickData ^ 1]);
				currentTickData ^= 1;
			}
		}
		case ReplayType_Cheater:
		{
			int replayLength = recordedRecentData[client].Length;
			for (int i = 0; i < replayLength; i++)
			{
				bool isKeyframe = (i % RP_TICKS_KEYFRAME_INTERVAL) == 0;
				if (isKeyframe)
				{
					int entry[2];
					entry[0] = i;
					entry[1] = WriteCache_BytesWritten();
					keyframes.PushArray(entry, sizeof(entry));
				}
				int rollingI = RecordingIndexAdd(client, i);
				recordedRecentData[client].GetArray(rollingI, tickData[currentTickData]);
				WriteTickDataThroughWriteCache(isKeyframe, tickData[currentTickData], tickData[currentTickData ^ 1]);
				currentTickData ^= 1;
			}
			
		}
		case ReplayType_Jump:
		{
			int replayLength = 2 * preAndPostRunTickCount + airtime;
			for (int i = 0; i < replayLength; i++)
			{
				bool isKeyframe = (i % RP_TICKS_KEYFRAME_INTERVAL) == 0;
				if (isKeyframe)
				{
					int entry[2];
					entry[0] = i;
					entry[1] = WriteCache_BytesWritten();
					keyframes.PushArray(entry, sizeof(entry));
				}
				int rollingI = RecordingIndexAdd(client, i - replayLength);
				recordedRecentData[client].GetArray(rollingI, tickData[currentTickData]);
				WriteTickDataThroughWriteCache(isKeyframe, tickData[currentTickData], tickData[currentTickData ^ 1]);
				currentTickData ^= 1;
			}
		}
	}

	// Keyframe trailer: count x { u32 tickIndex, u32 fileOffset }, then u32 count
	// as the LAST 4 bytes of the section payload, so the loader can find it at
	// (payloadStart + length - 4) without first decoding the tick stream.
	int keyframeCount = keyframes.Length;
	int entry[2];
	for (int k = 0; k < keyframeCount; k++)
	{
		keyframes.GetArray(k, entry, sizeof(entry));
		WriteCache_WriteInt32(entry[0]);
		WriteCache_WriteInt32(entry[1]);
	}
	WriteCache_WriteInt32(keyframeCount);
	delete keyframes;

	WriteCache_Flush();
}

static void WriteTickDataThroughWriteCache(bool isFirstTick, const any tickData[RP_V2_TICK_DATA_BLOCKSIZE], const any prevTickData[RP_V2_TICK_DATA_BLOCKSIZE])
{
	int deltaFlags = (1 << RPDELTA_DELTAFLAGS);
	if (isFirstTick)
	{
		// NOTE: Set every bit to 1 until RP_V2_TICK_DATA_BLOCKSIZE.
		deltaFlags = (1 << (RP_V2_TICK_DATA_BLOCKSIZE)) - 1;
	}
	else
	{
		// NOTE: Test tickData against prevTickData for differences.
		for (int i = 1; i < RP_V2_TICK_DATA_BLOCKSIZE; i++)
		{
			// If the bits in tickData[i] are different to prevTickData[i], then
			// set the corresponding bitflag.
			if (tickData[i] ^ prevTickData[i])
			{
				deltaFlags |= (1 << i);
			}
		}
	}

	WriteCache_WriteData(deltaFlags);
	// NOTE: write only data that has changed since the previous tick.
	for (int i = 1; deltaFlags; i++)
	{
		deltaFlags >>= 1;
		if (deltaFlags & 1)
		{
			WriteCache_WriteData(tickData[i]);
		}
	}
}

static void FormatCheaterReplayPath(char[] buffer, int maxlength, int client, int mode, int style)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%d_%s_%d_%s_%s.%s",
		RP_DIRECTORY_CHEATERS,
		GetSteamAccountID(client),
		gC_CurrentMap,
		GetTime(),
		gC_ModeNamesShort[mode], 
		gC_StyleNamesShort[style], 
		RP_FILE_EXTENSION);
}

static void FormatJumpReplayPath(char[] buffer, int maxlength, int client, int jumpType, int mode, int style)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%d/%d_%s_%s.%s",
		RP_DIRECTORY_JUMPS,
		GetSteamAccountID(client),
		jumpType,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		RP_FILE_EXTENSION);
}

static void FormatBlockJumpReplayPath(char[] buffer, int maxlength, int client, int block, int jumpType, int mode, int style)
{
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%d/%s/%d_%d_%s_%s.%s",
		RP_DIRECTORY_JUMPS,
		GetSteamAccountID(client),
		RP_DIRECTORY_BLOCKJUMPS,
		jumpType,
		block,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		RP_FILE_EXTENSION);
}

static int EncodePlayerFlags(int client, int buttons, int tickCount)
{
	int flags = 0;
	MoveType movetype = Movement_GetMovetype(client);
	int clientFlags = GetEntityFlags(client);
	
	flags = view_as<int>(movetype) & RP_MOVETYPE_MASK;

	SetKthBit(flags, 4, IsBitSet(buttons, IN_ATTACK));
	SetKthBit(flags, 5, IsBitSet(buttons, IN_ATTACK2));
	SetKthBit(flags, 6, IsBitSet(buttons, IN_JUMP));
	SetKthBit(flags, 7, IsBitSet(buttons, IN_DUCK));
	SetKthBit(flags, 8, IsBitSet(buttons, IN_FORWARD));
	SetKthBit(flags, 9, IsBitSet(buttons, IN_BACK));
	SetKthBit(flags, 10, IsBitSet(buttons, IN_LEFT));
	SetKthBit(flags, 11, IsBitSet(buttons, IN_RIGHT));
	SetKthBit(flags, 12, IsBitSet(buttons, IN_MOVELEFT));
	SetKthBit(flags, 13, IsBitSet(buttons, IN_MOVERIGHT));
	SetKthBit(flags, 14, IsBitSet(buttons, IN_RELOAD));
	SetKthBit(flags, 15, IsBitSet(buttons, IN_SPEED));
	SetKthBit(flags, 16, IsBitSet(buttons, IN_USE));
	SetKthBit(flags, 17, IsBitSet(buttons, IN_BULLRUSH));
	SetKthBit(flags, 18, IsBitSet(clientFlags, FL_ONGROUND));
	SetKthBit(flags, 19, IsBitSet(clientFlags, FL_DUCKING));
	SetKthBit(flags, 20, IsBitSet(clientFlags, FL_SWIM));

	SetKthBit(flags, 21, GetEntProp(client, Prop_Data, "m_nWaterLevel") != 0);

	SetKthBit(flags, 22, isTeleportTick[client]);
	SetKthBit(flags, 23, Movement_GetTakeoffTick(client) == tickCount);
	SetKthBit(flags, 24, GOKZ_GetHitPerf(client));
	SetKthBit(flags, 25, IsCurrentWeaponSecondary(client));

	return flags;
}

// Function to set the bitNum bit in integer to value
static void SetKthBit(int &number, int offset, bool value)
{
	int intValue = value ? 1 : 0;
	number |= intValue << offset;
}

static bool IsBitSet(int number, int checkBit)
{
	return (number & checkBit) ? true : false;
}

static int GetPlayerWeaponSlotDefIndex(int client, int slot)
{
	int ent = GetPlayerWeaponSlot(client, slot);
	
	// Nothing equipped in the slot
	if (ent == -1)
	{
		return -1;
	}
	
	return GetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex");
}

static bool IsCurrentWeaponSecondary(int client)
{
	int activeWeaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int secondaryEnt = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
	return activeWeaponEnt == secondaryEnt;
}

static void CreateReplaysDirectory()
{
	char path[PLATFORM_MAX_PATH];

	// Create parent replay directory
	BuildPath(Path_SM, path, sizeof(path), RP_DIRECTORY);
	CreateDirectory(path, 511);

	// Create runs replay directory
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_RUNS);
	CreateDirectory(path, 511);

	// Create cheaters replay directory
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_CHEATERS);
	CreateDirectory(path, 511);

	// Create jumps parent replay directory
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_JUMPS);
	CreateDirectory(path, 511);

	// Create temp directory for streaming run-recording slots.
	BuildPath(Path_SM, path, sizeof(path), "%s", RP_DIRECTORY_TEMP);
	CreateDirectory(path, 511);
}

static void CleanReplaysTempDir()
{
	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "%s", RP_DIRECTORY_TEMP);

	DirectoryListing dl = OpenDirectory(dir);
	if (dl == null)
	{
		return;
	}

	char name[PLATFORM_MAX_PATH];
	char full[PLATFORM_MAX_PATH];
	FileType type;
	while (dl.GetNext(name, sizeof(name), type))
	{
		if (type != FileType_File)
		{
			continue;
		}
		FormatEx(full, sizeof(full), "%s/%s", dir, name);
		DeleteFile(full);
	}
	delete dl;
}

public void MYAWCheck(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		playerMYaw[client] = StringToFloat(cvarValue);
	}
}

public void SensitivityCheck(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		playerSensitivity[client] = StringToFloat(cvarValue);
	}
}

static int RecordingIndexAdd(int client, int offset)
{
	int index = recordingIndex[client] + offset;
	if (index < 0)
	{
		index += recordedRecentData[client].Length;
	}
	return index % recordedRecentData[client].Length;
}

static void RemoveFromRunningTimers(int client, Handle timerToRemove)
{
	int index = runningJumpstatTimers[client].FindValue(timerToRemove);
	if (index != -1)
	{
		runningJumpstatTimers[client].Erase(index);
	}
}



// =====[ RECORDING SLOT TEMP FILES ]=====
//
// Each client owns REC_NUM_SLOTS temp files under RP_DIRECTORY_TEMP.
// Each file holds packed (tick, netstats) records of size (RP_V2_TICK_DATA_BLOCKSIZE + sizeof(ReplayNetStats)) cells.
// Records are written sequentially during recording and rewound + read sequentially at Save time.

static void RecBuildPath(int client, int slot, char[] buffer, int maxlen)
{
	BuildPath(Path_SM, buffer, maxlen, "%s/c%d_s%d.bin", RP_DIRECTORY_TEMP, client, slot);
}

static void RecCloseSlot(int client, int slot)
{
	if (recSlotFile[client][slot] != null)
	{
		delete recSlotFile[client][slot];
	}
	recRecordCount[client][slot] = 0;
}

// Open in "wb+" so we keep read access for the Save-side rewind.
static void RecTruncateSlot(int client, int slot)
{
	char path[PLATFORM_MAX_PATH];

	if (recSlotFile[client][slot] != null)
	{
		delete recSlotFile[client][slot];
	}
	RecBuildPath(client, slot, path, sizeof(path));
	recSlotFile[client][slot] = OpenFile(path, "wb+");
	if (recSlotFile[client][slot] == null)
	{
		LogError("Failed to open slot temp file '%s'", path);
	}
	recRecordCount[client][slot] = 0;
}

static void RecAppendRecord(int client, int slot, ReplayTickData tickData, ReplayNetStats netStats)
{
	File f = recSlotFile[client][slot];
	if (f == null)
	{
		return;
	}
	f.Write(tickData, RP_V2_TICK_DATA_BLOCKSIZE, 4);
	f.Write(netStats, sizeof(ReplayNetStats), 4);
	recRecordCount[client][slot]++;
}



// =====[ WRITE CACHE ]=====
//
// Byte-addressable buffer that batches small file writes into one bulk write per ~64 KB to slash IFileSystem syscall count.
// Bytes are packed 4-per-cell little-endian so the buffer occupies 64 KB of data segment and the bulk flush emits the full cells via file.Write(buf, n, 4) 
// Trailing 0-3 unaligned bytes are written individually.
//
// Usage:
//   WriteCache_SetFile(file);
//   WriteCache_WriteInt32(...); // ...repeat for whole payload...
//   WriteCache_Flush();         // appends buffered bytes to file
//
// Autoflushes midwrite when full, so payloads larger than the buffer still work

#define WRITE_CACHE_CELLS 16384
#define WRITE_CACHE_BYTES (WRITE_CACHE_CELLS * 4)

static File writeCacheFile;
static int writeCacheNext;                 // byte position in cache
static int writeCacheTotalBytes;           // cumulative bytes routed through cache since SetFile (incl. flushed)
static int writeCache[WRITE_CACHE_CELLS];  // 4 bytes per cell, LE packed => 64 KB capacity

static void WriteCache_SetFile(File file)
{
	writeCacheFile = file;
	writeCacheNext = 0;
	writeCacheTotalBytes = 0;
}

static int WriteCache_BytesWritten()
{
	return writeCacheTotalBytes;
}

static void WriteCache_Flush()
{
	if (writeCacheNext == 0)
	{
		return;
	}

	int fullCells = writeCacheNext >> 2;
	int tailBytes = writeCacheNext & 3;

	if (fullCells > 0)
	{
		writeCacheFile.Write(writeCache, fullCells, 4);
	}
	if (tailBytes > 0)
	{
		int tailCell = writeCache[fullCells];
		for (int i = 0; i < tailBytes; i++)
		{
			writeCacheFile.WriteInt8((tailCell >> (i * 8)) & 0xFF);
		}
	}

	writeCacheNext = 0;
}

static void WriteCache_WriteInt8(int v)
{
	if (writeCacheNext + 1 > WRITE_CACHE_BYTES)
	{
		WriteCache_Flush();
	}

	int idx = writeCacheNext >> 2;
	int shift = (writeCacheNext & 3) * 8;
	if (shift == 0)
	{
		writeCache[idx] = v & 0xFF;
	}
	else
	{
		writeCache[idx] |= (v & 0xFF) << shift;
	}
	writeCacheNext++;
	writeCacheTotalBytes++;
}

static void WriteCache_WriteInt16(int v)
{
	WriteCache_WriteInt8(v & 0xFF);
	WriteCache_WriteInt8((v >> 8) & 0xFF);
}

static void WriteCache_WriteInt32(int v)
{
	// Store the whole cell in one op. TICKS routes every write through WriteInt32 (via WriteCache_WriteData) starting from offset 0,
	// so it stays on this path end-to-end.
	if ((writeCacheNext & 3) == 0)
	{
		if (writeCacheNext + 4 > WRITE_CACHE_BYTES)
		{
			WriteCache_Flush();
		}
		writeCache[writeCacheNext >> 2] = v;
		writeCacheNext += 4;
		writeCacheTotalBytes += 4;
		return;
	}

	WriteCache_WriteInt8(v & 0xFF);
	WriteCache_WriteInt8((v >> 8) & 0xFF);
	WriteCache_WriteInt8((v >> 16) & 0xFF);
	WriteCache_WriteInt8((v >> 24) & 0xFF);
}

static void WriteCache_WriteString(const char[] s, int byteCount)
{
	for (int i = 0; i < byteCount; i++)
	{
		WriteCache_WriteInt8(s[i]);
	}
}

// Legacy alias kept for callers that pass `any` (a 4-byte cell).
static void WriteCache_WriteData(any data)
{
	WriteCache_WriteInt32(view_as<int>(data));
}
