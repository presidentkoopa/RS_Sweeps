// RS_Sweeps -- the engine.
//
// Bands of light travelling through the world, tested per pixel against world
// position on every surface, so one band wraps across floor, wall and ceiling
// as a single unbroken line. A sector's glow is uniform across that sector;
// this is not per-sector at all.
//
// EIGHT SLOTS, THREE SOURCES.
//
// The engine gives eight band slots and they are a shared, fixed resource. The
// three sources -- standing bands, a ping from the player, and bands fired by
// things that happen -- all want them, so the allocation is explicit rather
// than first-come:
//
//   slots 0 .. ambientCount-1   standing bands (at most seven with the ping on)
//   slot  7                     the ping, when it is on
//   the rest, from 6 downward   fired bands, newest first
//
// Ambient wins ties because it is the one you notice missing. Turn the ambient
// count up to eight and events have nowhere to go -- the menu says so rather
// than silently dropping them.
//
// NOT THE ONLY CALLER. The weapon wheel draws its opening ring in band 0, and
// any other mod in the family is free to borrow a band. So the push switches
// off only the slots it wrote itself last time, never "every slot not in use".
// That rule erased the wheel's ring every frame: UiTick runs after every
// WorldTick, so this was always the last writer before the picture.
//
// A FIRED BAND IS A TRACKED OBJECT, not just a push to the shader. It keeps its
// origin, its birth time and its speed on this side, so "where is the front
// now" and "has it passed this actor yet" are answerable questions. Crossings
// and every registered effect hang on exactly that -- a band that re-tiers what
// it washes over needs this and nothing more.
//
// NETPLAY: SHARED BANDS AND LOCAL ONES. The crossings run in the playsim and
// some effects change the game, so a band that runs them has to be the same
// band on every machine. Most are: a kill or an explosion happens everywhere,
// and a Once pass from the map origin, a fixed point or the map centre is
// worked out from server cvars and the map. Two are not. A "follows you"
// standing band leaves from each machine's own camera, and "when YOU are hurt"
// fires for consoleplayer only. Those are LOCAL. In a multiplayer game an
// effect that is not look-only (RSS_Effect.LookOnly) hears only SHARED bands,
// and a local fired band never takes a slot a shared one would get, or ends
// one early, so where the shared bands are is the same on every machine too.
// In single player every effect hears every band, as it always has.

class RSS_Handler : EventHandler
{
	const SLOTS = 8;
	const PING_SLOT = 7;

	// Band shapes, as the engine numbers them.
	const SH_RING   = 1;   // rings expanding across the floor plane
	const SH_BARX   = 2;   // bars sweeping east/west
	const SH_BARY   = 3;   // bars sweeping north/south
	const SH_SHELL  = 4;   // spheres, so a band rises as it grows
	const SH_RISE   = 5;   // a horizontal plane climbing
	// SIGNED. One front crossing the level, which is what the word means.
	// 2 and 3 are abs() -- two planes moving apart from the middle, a split.
	const SH_SWEEPX  = 6;  // west to east
	const SH_SWEEPY  = 7;  // south to north
	const SH_SWEEPNX = 8;  // east to west
	const SH_SWEEPNY = 9;  // north to south

	// Draw modes.
	const DR_ADD      = 1;
	const DR_LIFT     = 2;
	const DR_CRUSH    = 3;
	// Blends the GLOW the band covers toward the band's own colour, so the
	// colour change itself travels across a wall. The shader has carried it
	// all along; nothing here could send it. Draws nothing where there is no
	// glow to recolour.
	const DR_RECOLOUR = 4;

	// How the standing bands are timed -- see rss_ambient_timing in cvarinfo.
	const TM_SPREAD = 0;
	const TM_TRAIN  = 1;
	const TM_ONCE   = 2;

	// The after-look's parked band -- see ParkRadius. Slot 0, because it is the
	// slot a pass's lead band already held, so the hand-over from travelling to
	// parked writes the same slot on consecutive tics and nothing is let go in
	// between.
	const PARK_SLOT = 0;
	const PARK_PAST = 65536.0;

	// ---- fired bands -------------------------------------------------------
	//
	// Parallel arrays rather than a class per band: there are at most eight,
	// they are pure data, and an array of objects would mean allocation on
	// every kill.
	private Vector3 evOrigin[SLOTS];
	private double  evBorn[SLOTS];     // level.maptime when it was fired
	private double  evLife[SLOTS];     // in tics, speed already applied
	private double  evReach[SLOTS];    // how far it travels, in map units
	private int     evShape[SLOTS];
	private bool    evLive[SLOTS];
	// The same band on every machine -- see NETPLAY at the top. False only for
	// a band fired from something one machine sees alone.
	private bool    evShared[SLOTS];
	// Where the front was LAST tic. The crossing test is a threshold -- behind
	// this thing then, past it now -- so it needs both edges.
	private double  evPrevFront[SLOTS];

	// The ping.
	private double pingBorn;
	private bool   pingLive;

	// ---- the one-pass sweep ------------------------------------------------
	//
	// Timing ONCE: the standing bands cross the level a single time when sent
	// -- at map start, or by the rss_sweep network event -- and then stay off
	// until sent again. A slow wall crossing the map with the place changed
	// behind it, which a loop cannot be: a band that restarts would re-apply
	// its effects every cycle, so only a Once pass runs them.
	private double onceBorn;           // level.maptime the pass was sent
	private bool   onceLive;
	// Each standing band's front LAST tic, for the same threshold test the
	// fired bands use.
	private double stPrevFront[SLOTS];

	// ---- the after-look ----------------------------------------------------
	//
	// Behind the line the world is different. The engine grades everything a
	// band's front has already crossed, per pixel -- but only while that band is
	// live. So a Once pass that has arrived leaves ONE band behind, parked past
	// the far edge at brightness 0, and the look stays for the rest of the map.
	// One is enough: every band of a pass shares its shape and origin and ends
	// on the same line, so a second parked band would grade exactly the same
	// ground and cost a slot the fired bands could have had.
	//
	// The geometry is taken when the pass ends and then held still. A pass
	// following you moves with you while it travels; the line it leaves does
	// not. Saved with the level, so a save loaded on this map keeps the look.
	// Replaced by the next pass, dropped by a map change or by the timing
	// leaving Once. Not a live band as far as the Effects are concerned -- they
	// were told the pass ended, and put back what they hold as they always did.
	private bool    parked;
	private Vector3 parkOrigin;
	private int     parkShape;
	private double  parkReach;

	// The slots the last UiTick push wrote, one bit each. UI SCOPE because it
	// is written from UiTick, and it is the only record of which bands are
	// ours: there is no getter to ask the engine, so this is what lets the push
	// hand back exactly what it held and nothing another caller put there.
	private ui transient int heldSlots;

	// Where YOU are, for "follows you". Resolved in play scope because it reads
	// the world; the other origin modes are worked out from cvars in
	// AnchorPoint, which UiTick can run, so the look is pushed from clearscope
	// and the menu moves the picture while the game is paused.
	private Vector3 anchor;
	private bool anchorValid;

	// The map's own extent, measured once. A sweep -- the actual meaning of the
	// word, one front crossing the level from one end to the other -- has to
	// start off the near edge and reach the far one, and neither number is
	// knowable without asking the geometry.
	private double mapMinX, mapMaxX, mapMinY, mapMaxY;
	private bool mapMeasured;

	// The middle of the box round every SECTOR'S CENTRE -- not round the
	// vertexes. That is how GlowInTheDark finds its map centre, and a band
	// carried over from it has to leave from the same spot it did there. The two
	// boxes differ on any map with a long thin outer sector.
	private Vector2 mapCentre;

	// ---- lifecycle ---------------------------------------------------------

	// Measured from the vertexes, once. Cheap even on a large map and it cannot
	// change while the map is loaded.
	void MeasureMap()
	{
		mapMeasured = true;

		mapCentre = (0, 0);
		if (Level && Level.Sectors.Size() > 0)
		{
			double cx0 = 1e30, cx1 = -1e30, cy0 = 1e30, cy1 = -1e30;
			for (int i = 0; i < Level.Sectors.Size(); i++)
			{
				Vector2 c = Level.Sectors[i].centerspot;
				if (c.x < cx0) cx0 = c.x;
				if (c.x > cx1) cx1 = c.x;
				if (c.y < cy0) cy0 = c.y;
				if (c.y > cy1) cy1 = c.y;
			}
			mapCentre = ((cx0 + cx1) * 0.5, (cy0 + cy1) * 0.5);
		}

		if (!Level || Level.Vertexes.Size() == 0)
		{
			mapMinX = mapMinY = -4096; mapMaxX = mapMaxY = 4096;
			return;
		}
		mapMinX = mapMinY =  1e30;
		mapMaxX = mapMaxY = -1e30;
		for (int i = 0; i < Level.Vertexes.Size(); i++)
		{
			Vector2 v = Level.Vertexes[i].p;
			if (v.x < mapMinX) mapMinX = v.x;
			if (v.x > mapMaxX) mapMaxX = v.x;
			if (v.y < mapMinY) mapMinY = v.y;
			if (v.y > mapMaxY) mapMaxY = v.y;
		}
	}

	clearscope static bool IsCrossing(int shape)
	{
		return shape >= SH_SWEEPX && shape <= SH_SWEEPNY;
	}

	// How far a band of this shape must travel to cross the whole map, and
	// where it has to start. Signed shapes only -- everything else keeps its
	// own origin and its own reach.
	clearscope double SweepSpan(int shape) const
	{
		if (shape == SH_SWEEPX || shape == SH_SWEEPNX) return mapMaxX - mapMinX;
		if (shape == SH_SWEEPY || shape == SH_SWEEPNY) return mapMaxY - mapMinY;
		return 0.0;
	}

	// How much map is left in front of a point, for a sweep that starts
	// somewhere other than the edge.
	clearscope double SpanFrom(int shape, Vector3 at) const
	{
		if (shape == SH_SWEEPX)  return max(mapMaxX - at.x, 1.0);
		if (shape == SH_SWEEPNX) return max(at.x - mapMinX, 1.0);
		if (shape == SH_SWEEPY)  return max(mapMaxY - at.y, 1.0);
		if (shape == SH_SWEEPNY) return max(at.y - mapMinY, 1.0);
		return 1.0;
	}

	// `pad` back from the near edge, so the band starts wholly off the map
	// rather than centred on its boundary with half of it already drawn.
	clearscope Vector3 SweepStart(int shape, double pad) const
	{
		double z = 0;
		if (shape == SH_SWEEPX)  return (mapMinX - pad, (mapMinY + mapMaxY) * 0.5, z);
		if (shape == SH_SWEEPNX) return (mapMaxX + pad, (mapMinY + mapMaxY) * 0.5, z);
		if (shape == SH_SWEEPY)  return ((mapMinX + mapMaxX) * 0.5, mapMinY - pad, z);
		if (shape == SH_SWEEPNY) return ((mapMinX + mapMaxX) * 0.5, mapMaxY + pad, z);
		return AnchorPoint();
	}

	// HOW FAR PAST AN EDGE a crossing band has to start and finish so that it
	// enters and leaves whole. The band reaches `thick` either side of its
	// front, and the wake stretches one side to |rss_trail| when that is the
	// longer -- see SweepBandAttenAt in main.fp. Without this the front pops in
	// half-drawn on the near edge and is cut off short of the far one.
	clearscope static double SweepPad(double thick)
	{
		return max(thick, abs(RSS.GetF("rss_trail", 0.0)));
	}

	override void WorldLoaded(WorldEvent e)
	{
		MeasureMap();

		// Whatever the effects still hold from the last map -- a drain, a fog
		// tint, a darkness offset -- is put back BEFORE they are replaced below,
		// because the fresh copies would never know it was there.
		ResetEffects();

		// The built-ins register themselves. Each is inert until its own switch
		// is on, and says so through WantsSectors/WantsActors, so registering
		// them all costs nothing while they are off.
		Register(new("RSS_FxFogRipple"), "fog");
		Register(new("RSS_FxRecolour"),  "recolour");
		Register(new("RSS_FxRouse"),     "rouse");
		Register(new("RSS_FxCrossed"),   "crossed");
		Register(new("RSS_FxGlow"),      "glow");
		Register(new("RSS_FxLight"),     "light");
		Register(new("RSS_FxFogTint"),   "fogtint");
		Register(new("RSS_FxDarken"),    "darken");
		Register(new("RSS_FxDesat"),     "desat");
		Register(new("RSS_FxDecor"),     "decor");

		SyncPreset();
		for (int i = 0; i < SLOTS; i++) evLive[i] = false;
		pingLive = false;
		// A pass in flight is dropped on a save load, the same as the fired
		// bands above. A new map sends one when Once is the timing -- the map
		// starting is one of the two things that send it.
		onceLive = false;
		// A parked after-look belongs to this map. A save loaded on it keeps
		// the look, the same as the glow and light a pass left in the sectors.
		if (!e.IsSaveGame) parked = false;
		anchorValid = false;
		ResolveAnchor();
		if (!e.IsSaveGame && RSS.GetB("rss_enabled", true) && StandingTiming() == TM_ONCE)
			StartOncePass();
		Push();
	}

	override void WorldUnloaded(WorldEvent e)
	{
		ResetEffects();
		// The bands are level state, not mod state. Leaving them set means the
		// next map opens wearing the last one.
		if (Level) Level.ClearSweep();
	}

	override void WorldTick()
	{
		// First, so a map loaded from a save has its glow claims standing
		// again before anything paints -- see PublishClaims.
		PublishClaims();
		SyncPreset();
		ResolveAnchor();
		// Crossings BEFORE ageing, so the tic a band reaches the end of its
		// travel still walks that last stretch and only then tells the effects
		// it ended. The other way round, the final stretch of every band was
		// never crossed at all.
		Crossings();
		AgeBands();
		TicDone();
		Push();
	}

	// The playsim stops while the menu is up, so WorldTick alone would freeze
	// the picture exactly while the slider meant to change it is dragged. Every
	// sweep setter is clearscope for this reason.
	//
	// Bands are NOT aged from here. Ageing is the passage of time in the world,
	// and a fired band creeping outward while the game is paused would be
	// wrong. "Follows you" is not resolved here either -- it reads the world.
	//
	// Letting go of slots happens HERE and only here. UiTick runs after
	// WorldTick every tic, paused or not, so it always has the final say, and
	// it is the one place the held set can be kept.
	override void UiTick()
	{
		SyncPreset();
		int wrote = Push();
		ReleaseSlots(heldSlots & ~wrote, wrote == 0);
		heldSlots = wrote;
	}

	// The rss_sweep network event sends one Once pass. KEYCONF binds it as
	// rss_sweep_now. A network event rather than a console command so every
	// client starts the pass on the same tic.
	override void NetworkProcess(ConsoleEvent e)
	{
		if (!(e.Name ~== "rss_sweep")) return;
		if (!RSS.GetB("rss_enabled", true)) return;
		if (StandingTiming() != TM_ONCE) return;
		StartOncePass();
	}

	clearscope void SyncPreset()
	{
		int want = RSS.GetI("rss_preset", 1);
		if (want < 0 || want >= RSS_Presets.COUNT) want = 1;
		if (want == RSS.GetI("rss_preset_applied", -1)) return;
		RSS_Presets.Apply(want);
		RSS.SetI("rss_preset_applied", want);
	}

	// ---- where the standing bands come from --------------------------------

	// Where you are, for "follows you". Tracked whatever the mode, so switching
	// to follows you in the menu starts from where you were standing rather
	// than from the map origin.
	//
	// LOCAL. consoleplayer's camera is a different place on every machine, so
	// nothing gameplay may hang on it -- see StandingShared.
	void ResolveAnchor()
	{
		let cam = players[consoleplayer].camera;
		if (cam)
		{
			anchor = cam.pos;
			anchorValid = true;
		}
	}

	// THE ORIGIN the standing bands and the ping use. Only "follows you" needs
	// the world; map origin, the fixed point and the map centre come from cvars
	// and the map, so they are answered here in clearscope and their sliders
	// move the bands while the menu is open. They used to be resolved in
	// WorldTick with the rest, and did nothing until the menu closed.
	clearscope Vector3 AnchorPoint() const
	{
		int mode = RSS.GetI("rss_ambient_org", 1);
		if (mode == 1)
		{
			if (anchorValid) return anchor;
			return (0, 0, 0);
		}
		if (mode == 2)
		{
			return (RSS.GetF("rss_ambient_x"), RSS.GetF("rss_ambient_y"),
				RSS.GetF("rss_ambient_z"));
		}
		if (mode == 3) return (mapCentre.x, mapCentre.y, 0);
		return (0, 0, 0);
	}

	// WHETHER THE STANDING BANDS ARE THE SAME ON EVERY MACHINE. "Follows you"
	// leaves from each machine's own camera, and is LOCAL even before the
	// camera is known; every other origin comes from server cvars and the map.
	// Decides whether a Once pass runs gameplay effects in a netgame.
	clearscope static bool StandingShared()
	{
		return RSS.GetI("rss_ambient_org", 1) != 1;
	}

	clearscope int StandingTiming() const
	{
		return clamp(RSS.GetI("rss_ambient_timing", TM_SPREAD), TM_SPREAD, TM_ONCE);
	}

	// Clamped to the LAST shape, the signed sweeps included -- clamping to
	// SH_RISE turned every sweep into a rising plane before it got anywhere.
	clearscope int StandingShape() const
	{
		return clamp(RSS.GetI("rss_ambient_shape", SH_RING), SH_RING, SH_SWEEPNY);
	}

	// How many standing bands there are. With the ping on the top slot is the
	// ping's, so at most seven stand -- the ping used to be written straight
	// over band eight.
	clearscope int StandingCount() const
	{
		if (!RSS.GetB("rss_ambient", true)) return 0;
		int top = RSS.GetB("rss_ping", false) ? PING_SLOT : SLOTS;
		return clamp(RSS.GetI("rss_ambient_count", 2), 0, top);
	}

	// The pad for the widest standing band. The per-band table can make one
	// wider than the shared thickness, and the pad has to clear that one too.
	clearscope double StandingPad(int amb) const
	{
		double thick = RSS.GetF("rss_thickness", 26.0);
		double widest = thick;
		for (int i = 0; i < amb; i++) widest = max(widest, StandingThick(i, thick));
		return SweepPad(widest);
	}

	// A SIGNED SHAPE CROSSES THE MAP. It ignores the reach slider on purpose: a
	// sweep that stops halfway is not a sweep, so the geometry decides how far
	// it goes. The origin setting only picks which of the two crossings it is.
	//
	// FROM THE EDGE, or FROM WHERE YOU ARE. From the edge -- any origin but
	// "follows you" -- is the plain reading: one front crossing the whole map,
	// starting `pad` off the near edge and running on `pad` past the far one,
	// so it enters and leaves whole. From you is the other one worth having:
	// the front starts at your feet and travels outward, so the level changes
	// away from you rather than arriving at you, and the reach is only as far
	// as it still has map to cross.
	// rss_cross_always (owner, 2026-09-18) settles the contradiction between a
	// shape that says CROSS THE MAP and an origin that says START AT ME: with it
	// on, a signed shape always leaves the edge. Only crossing shapes ask this --
	// rings, bars and shells keep using Centred on as they always did.
	clearscope bool SweepFromYou() const
	{
		if (RSS.GetB("rss_cross_always", true)) return false;
		return RSS.GetI("rss_ambient_org", 1) == 1 && anchorValid;
	}

	clearscope Vector3 StandingOrigin(int shape, double pad) const
	{
		if (!IsCrossing(shape)) return AnchorPoint();
		if (SweepFromYou()) return anchor;
		return SweepStart(shape, pad);
	}

	clearscope double StandingReach(int shape, double pad) const
	{
		double reach = RSS.GetF("rss_ambient_reach", 900.0);
		if (!IsCrossing(shape)) return reach;
		if (SweepFromYou()) return SpanFrom(shape, anchor) + pad;
		double span = SweepSpan(shape);
		return (span > 1.0) ? span + 2.0 * pad : reach;
	}

	// PROGRESS OF STANDING BAND i THROUGH A ONCE PASS: 0 to 1 while it is
	// travelling, below 0 before it has left, 1 and above once it has arrived.
	// One pass takes 1/Speed seconds, and the bands leave the same fraction of
	// a pass apart that Spread puts them round a cycle.
	clearscope double OnceT(int i, int amb) const
	{
		double secs = (level.maptime - onceBorn) / 35.0;
		return secs * max(RSS.GetF("rss_ambient_speed", 0.35), 0.0)
			- double(i) / max(amb, 1);
	}

	// ---- the one-pass sweep ------------------------------------------------

	void StartOncePass()
	{
		// A pass already crossing is ended properly first, so an effect holding
		// something for it lets go before the new front picks it up again.
		if (onceLive) EndOncePass();
		// The new pass REPLACES the line the last one left. Its own front
		// carries the look again from where it starts.
		parked = false;
		onceBorn = level.maptime;
		onceLive = true;
		for (int i = 0; i < SLOTS; i++) stPrevFront[i] = 0.0;
	}

	void EndOncePass()
	{
		onceLive = false;
		// One end per standing band, and at least one, so an effect that held
		// something for the pass always hears that it finished -- even when the
		// standing count was dropped to 0 under it.
		int n = max(StandingCount(), 1);
		Vector3 org = StandingOrigin(StandingShape(), StandingPad(n));
		bool shared = StandingShared();
		for (int i = 0; i < n; i++) NotifyBandEnd(org, shared);
	}

	// A pass that ARRIVED leaves its line behind while the after-look is on.
	// Called before EndOncePass, while the pass's geometry still answers the
	// way it did on its last travelling tic. A pass cut short -- the timing
	// changed, the bands or the mod switched off under it -- leaves nothing.
	void ParkOncePass(int amb)
	{
		int shape = StandingShape();
		double pad = StandingPad(amb);
		parkShape = shape;
		parkOrigin = StandingOrigin(shape, pad);
		parkReach = StandingReach(shape, pad);
		parked = true;
	}

	// ---- firing ------------------------------------------------------------

	// Claim a slot for a fired band. Counts DOWN from just under the ping, so
	// the standing bands at the bottom are never disturbed, and recycles the
	// oldest when the allowance is full -- a busy room should show the most
	// recent kills rather than refusing to show any.
	//
	// `shared` false for a band only this machine fires -- see NETPLAY at the
	// top. In a multiplayer game a local band is invisible to a shared band's
	// pick: its slot counts as free, it does not fill the allowance, and it is
	// never the oldest one recycled. A local band takes a free slot under the
	// allowance, or recycles an older local band, or is not fired. So which
	// slot a shared band gets, and when it ends, is the same on every machine.
	// In single player every band is picked the one way it always was.
	void Fire(Vector3 at, int shape, bool shared = true)
	{
		if (!RSS.GetB("rss_enabled", true)) return;
		// An invisible band changes nothing. At brightness 0 -- the Off preset
		// -- a kill still fired a band nobody could see, and it still ran every
		// effect: retiering, darkening and draining the level behind a front
		// that was not there.
		if (RSS.GetF("rss_intensity", 1.3) <= 0.0) return;

		int allow = clamp(RSS.GetI("rss_ev_slots", 4), 0, SLOTS);
		if (allow <= 0) return;

		int lowest = StandingCount();
		int top = RSS.GetB("rss_ping", false) ? PING_SLOT - 1 : PING_SLOT;
		int used = 0, pick = -1;
		double oldest = 1e30;
		int oldestIdx = -1;
		bool split = multiplayer;

		for (int i = top; i >= lowest; i--)
		{
			bool taken = evLive[i] && !(split && shared && !evShared[i]);
			if (!taken) { if (pick < 0) pick = i; continue; }
			used++;
			if (split && !shared && evShared[i]) continue;
			if (evBorn[i] < oldest) { oldest = evBorn[i]; oldestIdx = i; }
		}

		if (used >= allow) pick = oldestIdx;
		if (pick < 0) return;

		// A recycled band ENDS, and the effects are told so, before its slot is
		// reused -- "ran out of life or was recycled" is what OnBandEnd promises.
		if (evLive[pick])
		{
			evLive[pick] = false;
			NotifyBandEnd(evOrigin[pick], evShared[pick]);
		}

		// SPEED IS TIME, NOT DISTANCE. It used to multiply the reach, so a sweep
		// at half speed stopped halfway across the map, one above 1 sat off the
		// far edge for the rest of its life, and a ring's Reach was never its
		// reach. Now a band always travels exactly its reach, and speed only
		// changes how long that takes.
		double speed = max(RSS.GetF("rss_ev_speed", 1.0), 0.05);

		evOrigin[pick] = at;
		evBorn[pick] = level.maptime;
		evLife[pick] = max(RSS.GetF("rss_ev_life", 1.1), 0.05) * 35.0 / speed;
		// A signed shape fired from a thing crosses the rest of the map from
		// where that thing was standing, and on past the far edge until it has
		// left whole. Anything else uses its own reach.
		evReach[pick] = IsCrossing(shape)
			? SpanFrom(shape, at) + SweepPad(RSS.GetF("rss_thickness", 26.0))
			: RSS.GetF("rss_ev_reach", 700.0);
		evShape[pick] = shape;
		evLive[pick] = true;
		evShared[pick] = shared;
		evPrevFront[pick] = 0.0;

		// A shared band does not count the local ones, so in a netgame it can
		// take the live total past the allowance. The oldest local band gives
		// way; that is this machine's picture only.
		if (split && shared)
		{
			int live = 0, oldLocal = -1;
			double oldLocalBorn = 1e30;
			for (int i = top; i >= lowest; i--)
			{
				if (!evLive[i]) continue;
				live++;
				if (!evShared[i] && evBorn[i] < oldLocalBorn)
				{
					oldLocalBorn = evBorn[i];
					oldLocal = i;
				}
			}
			if (live > allow && oldLocal >= 0)
			{
				evLive[oldLocal] = false;
				NotifyBandEnd(evOrigin[oldLocal], false);
			}
		}
	}

	// ---- what a band does to what it passes --------------------------------
	//
	// Registered effects live on RSS_Registry, a static handler, because
	// ZScript has no static data members and the list has to outlive any one
	// level -- a mod registers once and expects it to stick.
	//
	// AN ID IS REQUIRED. The registry replaces a same-id registration, so two
	// effects registered with none -- which the old example in rss_effects.zs
	// did -- silently replaced each other. Refused rather than guessed at.
	static bool Register(RSS_Effect fx, String id = "")
	{
		if (!fx) return false;
		if (id.Length() > 0) fx.id = id;
		if (fx.id.Length() == 0)
		{
			String cls = fx.GetClassName();
			Console.Printf("RS_Sweeps: effect %s registered with no id, refused.", cls);
			return false;
		}
		let reg = RSS_Registry.Get();
		if (!reg) return false;
		reg.Add(fx);
		return true;
	}

	// Whether any band that runs effects is still travelling -- a fired band or
	// a Once pass. For an effect deciding whether "a band ended" means "put it
	// all back" or "another one is still out there": the first band to end
	// used to undo what a second was still doing.
	//
	// `forGameplay` true asks only about the bands a gameplay effect hears --
	// in a netgame the shared ones, in single player all of them. A gameplay
	// effect deciding "that was the last band" has to ask it this way, or a
	// local band still out would make that decision differ between machines.
	static bool AnyBandLive(bool forGameplay = false)
	{
		let h = RSS_Handler(EventHandler.Find("RSS_Handler"));
		return h && h.HasLiveBand(forGameplay);
	}

	bool HasLiveBand(bool forGameplay = false) const
	{
		bool all = !forGameplay || !multiplayer;
		for (int i = 0; i < SLOTS; i++)
			if (evLive[i] && (all || evShared[i])) return true;
		return onceLive && (all || StandingShared());
	}

	// In a netgame an effect that is not look-only hears only shared bands --
	// see NETPLAY at the top.
	private static bool EffectHears(RSS_Effect fx, bool gameplay)
	{
		return fx && (gameplay || fx.LookOnly());
	}

	private void NotifyBandEnd(Vector3 origin, bool shared)
	{
		let reg = RSS_Registry.Get();
		if (!reg) return;
		bool gameplay = shared || !multiplayer;
		for (int k = 0; k < reg.effects.Size(); k++)
			if (EffectHears(reg.effects[k], gameplay)) reg.effects[k].OnBandEnd(origin);
	}

	private void TicDone()
	{
		let reg = RSS_Registry.Get();
		if (!reg) return;
		for (int k = 0; k < reg.effects.Size(); k++)
			if (reg.effects[k]) reg.effects[k].OnTicDone();
	}

	private void ResetEffects()
	{
		let reg = RSS_Registry.Get();
		if (!reg) return;
		for (int k = 0; k < reg.effects.Size(); k++)
			if (reg.effects[k]) reg.effects[k].ResetForMap();
	}

	// ---- claims on sector glow ---------------------------------------------
	//
	// The handler's half of RSS_SectorClaim, in rss_effects.zs -- read that
	// first.
	//
	// WHO PAINTED WHAT, one int per sector: the low four bits name the effect
	// that painted its wall glow, the next four its flat glow, 0 for nobody.
	// SAVED with the handler. The markers are client-side and a load drops
	// them, so this table is what puts them back. Sized on the first claim; a
	// map nothing has claimed keeps an empty one.
	private Array<int> claimOwner;

	// The markers, one per claimed sector, and the mask of effects some claim
	// still names. Transient: remade from claimOwner by PublishClaims on this
	// handler's first tic, and again after a load or a hub return.
	private transient Array<Actor> claimMarker;
	private transient int claimHeldBy;
	private transient bool claimsPublished;

	// For an effect: `parts` of this sector are now painted by `by`, one of the
	// RSS_SectorClaim.BY_ bits. The last painter of a part owns it.
	static void ClaimSector(Sector s, int parts, int by)
	{
		if (!s || parts == 0 || !ClaimBit(by)) return;
		let h = RSS_Handler(EventHandler.Find("RSS_Handler"));
		if (h) h.Claim(s.Index(), parts, by);
	}

	// For an effect: let go of every part `by` painted. Called every tic while
	// an effect is switched off, so it is one bit test until there is
	// something to let go of.
	static void ReleaseClaims(int by)
	{
		if (!ClaimBit(by)) return;
		let h = RSS_Handler(EventHandler.Find("RSS_Handler"));
		if (h) h.Release(by);
	}

	// One bit, and one that fits the four bits a part keeps it in.
	private static bool ClaimBit(int by)
	{
		return by > 0 && by <= 8 && (by & (by - 1)) == 0;
	}

	private void Claim(int idx, int parts, int by)
	{
		if (!Level) return;
		int n = Level.Sectors.Size();
		if (idx < 0 || idx >= n) return;
		PublishClaims();
		if (claimOwner.Size() != n) claimOwner.Resize(n);
		if (claimMarker.Size() != n) claimMarker.Resize(n);

		int own = claimOwner[idx];
		if (parts & RSS_SectorClaim.PART_WALLS) own = (own & ~15) | by;
		if (parts & RSS_SectorClaim.PART_FLATS) own = (own & 15) | (by << 4);
		claimOwner[idx] = own;
		claimHeldBy |= by;
		MarkClaim(idx);
	}

	private void Release(int by)
	{
		PublishClaims();
		if (!(claimHeldBy & by)) return;

		claimHeldBy = 0;
		for (int i = 0; i < claimOwner.Size(); i++)
		{
			int own = claimOwner[i];
			if (own == 0) continue;
			if ((own & 15) == by) own &= ~15;
			if (((own >> 4) & 15) == by) own &= 15;
			claimOwner[i] = own;
			claimHeldBy |= (own & 15) | ((own >> 4) & 15);
			MarkClaim(i);
		}
	}

	// THE MARKERS PUT BACK TO MATCH claimOwner, once per handler. The first tic
	// of a new map finds nothing to do. The first tic after a load or a hub
	// return finds the saved table and no markers, because client-side
	// thinkers are never saved.
	//
	// PLAY SCOPE, from WorldTick, which runs before UiTick on a tic -- so a
	// GlowInTheDark re-applying the map after a load finds the claims standing
	// before its write pass. A load with the console held down pauses the
	// world before that first WorldTick, and GITD may repaint the swept rooms
	// in that window.
	private void PublishClaims()
	{
		if (claimsPublished || !Level) return;
		claimsPublished = true;

		// Any marker still standing goes first. There are none after a load, but
		// a doubled claim is not worth betting a hub return on.
		let it = ThinkerIterator.Create("RSS_SectorClaim", Thinker.STAT_INFO, true);
		Actor stray;
		while (stray = Actor(it.Next())) stray.Destroy();

		// A table saved against a different sector count is some other map's.
		int n = Level.Sectors.Size();
		if (claimOwner.Size() != n) claimOwner.Clear();
		claimMarker.Clear();
		claimMarker.Resize(claimOwner.Size());
		claimHeldBy = 0;
		for (int i = 0; i < claimOwner.Size(); i++)
		{
			int own = claimOwner[i];
			if (own == 0) continue;
			claimHeldBy |= (own & 15) | ((own >> 4) & 15);
			MarkClaim(i);
		}
	}

	// Sector i's marker, brought in line with claimOwner: made, updated, or
	// taken away. Spawned client-side and moved to STAT_INFO -- see
	// RSS_SectorClaim for why both.
	private void MarkClaim(int i)
	{
		if (i < 0 || i >= claimOwner.Size() || i >= claimMarker.Size()) return;
		int own = claimOwner[i];
		int parts = 0;
		if (own & 15) parts |= RSS_SectorClaim.PART_WALLS;
		if ((own >> 4) & 15) parts |= RSS_SectorClaim.PART_FLATS;

		Actor m = claimMarker[i];
		if (parts == 0)
		{
			if (m) m.Destroy();
			claimMarker[i] = null;
			return;
		}
		if (!m)
		{
			let sec = Level.Sectors[i];
			m = Actor.SpawnClientSide("RSS_SectorClaim",
				(sec.centerspot.x, sec.centerspot.y, sec.floorplane.ZatPoint(sec.centerspot)));
			if (!m) return;
			m.ChangeStatNum(Thinker.STAT_INFO);
			m.args[0] = i;
			claimMarker[i] = m;
		}
		m.args[1] = parts;
	}

	// Distance from a band's origin to a point, in the band's own geometry.
	// MUST agree with SweepBandAttenAt in main.fp or the front the world reacts
	// to is not the front the player can see.
	//
	// Shader space is (x, z, y) -- its xz plane is the game's xy and its y is
	// the game's z -- so shape 3 measures along the game's Y.
	clearscope static double BandDistance(int shape, Vector3 org, Vector3 at)
	{
		if (shape == SH_BARX)  return abs(at.x - org.x);
		if (shape == SH_BARY)  return abs(at.y - org.y);
		if (shape == SH_RISE)  return at.z - org.z;
		if (shape == SH_SHELL) return (at - org).Length();
		// The signed four: one plane at org + distance, negative behind it, so
		// nothing behind where a sweep was fired from is ever crossed.
		if (shape == SH_SWEEPX)  return at.x - org.x;
		if (shape == SH_SWEEPY)  return at.y - org.y;
		if (shape == SH_SWEEPNX) return org.x - at.x;
		if (shape == SH_SWEEPNY) return org.y - at.y;
		return (at.xy - org.xy).Length();
	}

	// THE FRONTIER. Everything the front reached since last tic, once each.
	//
	// A threshold rather than a containment test: inside-the-band would fire
	// every tic for as long as the band covered a thing, and spawn-time would
	// treat the whole level as simultaneous and throw away the wave entirely.
	//
	// WHICH BANDS. Fired bands, and the standing bands while a Once pass is
	// crossing. Looping standing bands and the ping never run effects: a band
	// that restarts would re-apply them every cycle.
	//
	// The walk over sectors and actors happens only while some registered
	// effect wants it (WantsSectors/WantsActors) -- with every switch off, a
	// band costs nothing here. The fronts advance either way, so switching an
	// effect on mid-band starts from where the front is rather than crossing
	// everything it already passed in one tic.
	//
	// NETPLAY. A local band in a multiplayer game runs the look-only effects
	// alone, and is walked only if one of THOSE wants the level -- see NETPLAY
	// at the top.
	void Crossings()
	{
		let reg = RSS_Registry.Get();

		bool doSectors = false, doActors = false;
		bool lookSectors = false, lookActors = false;
		if (reg && RSS.GetB("rss_fx", false) && RSS.GetF("rss_intensity", 1.3) > 0.0)
		{
			bool sectorsOn = RSS.GetB("rss_fx_sectors", true);
			bool actorsOn = RSS.GetB("rss_fx_actors", true);
			for (int k = 0; k < reg.effects.Size(); k++)
			{
				let fx = reg.effects[k];
				if (!fx) continue;
				bool look = fx.LookOnly();
				if (sectorsOn && fx.WantsSectors()) { doSectors = true; if (look) lookSectors = true; }
				if (actorsOn && fx.WantsActors()) { doActors = true; if (look) lookActors = true; }
			}
		}

		// ---- fired bands ----
		for (int i = 0; i < SLOTS; i++)
		{
			if (!evLive[i]) continue;

			double front = FrontAt(i);
			double prev = evPrevFront[i];
			evPrevFront[i] = front;
			if (front <= prev) continue;

			// THE COLOUR THE BAND IS SHOWING RIGHT NOW, handed to every effect
			// so all of them agree. With a second colour mixed in this changes
			// as the band travels, which means one sweep can leave a gradient
			// of tiers and glow behind it rather than one flat answer.
			double prog = clamp((level.maptime - evBorn[i]) / max(evLife[i], 1.0), 0.0, 1.0);
			bool gameplay = evShared[i] || !multiplayer;
			WalkFront(reg, evShape[i], evOrigin[i], prev, front, BandColor(prog),
				gameplay ? doSectors : lookSectors, gameplay ? doActors : lookActors,
				gameplay);
		}

		// ---- a Once pass ----
		if (onceLive && StandingTiming() == TM_ONCE)
		{
			int amb = StandingCount();
			int shape = StandingShape();
			double pad = StandingPad(amb);
			Vector3 org = StandingOrigin(shape, pad);
			double reach = StandingReach(shape, pad);
			bool gameplay = StandingShared() || !multiplayer;
			bool passSectors = gameplay ? doSectors : lookSectors;
			bool passActors = gameplay ? doActors : lookActors;

			for (int i = 0; i < amb; i++)
			{
				double t = OnceT(i, amb);
				if (t <= 0.0) continue;
				t = min(t, 1.0);

				double front = t * reach;
				double prev = stPrevFront[i];
				stPrevFront[i] = front;
				if (front <= prev) continue;

				WalkFront(reg, shape, org, prev, front, StandingColor(i, t),
					passSectors, passActors, gameplay);
			}
		}
	}

	// One band's stretch of front, `prev` to `front`, handed to every effect:
	// the band first, then each sector and actor it reached. `gameplay` false
	// hands it to the look-only effects alone -- a local band in a netgame.
	private void WalkFront(RSS_Registry reg, int shape, Vector3 org,
		double prev, double front, Color tint, bool doSectors, bool doActors,
		bool gameplay)
	{
		if (!reg || (!doSectors && !doActors)) return;

		for (int k = 0; k < reg.effects.Size(); k++)
			if (EffectHears(reg.effects[k], gameplay)) reg.effects[k].OnFrontMoved(org, front, tint);

		if (doSectors)
		{
			for (int si = 0; si < Level.Sectors.Size(); si++)
			{
				let sec = Level.Sectors[si];
				Vector3 c = (sec.centerspot.x, sec.centerspot.y,
					sec.floorplane.ZatPoint(sec.centerspot));
				double d = BandDistance(shape, org, c);
				if (d < prev || d >= front) continue;
				for (int k = 0; k < reg.effects.Size(); k++)
					if (EffectHears(reg.effects[k], gameplay)) reg.effects[k].OnSector(sec, org, front, tint);
			}
		}

		if (doActors)
		{
			let it = ThinkerIterator.Create("Actor");
			Actor a;
			while (a = Actor(it.Next()))
			{
				if (!a) continue;
				double d = BandDistance(shape, org, a.pos);
				if (d < prev || d >= front) continue;
				for (int k = 0; k < reg.effects.Size(); k++)
					if (EffectHears(reg.effects[k], gameplay)) reg.effects[k].OnActor(a, org, front, tint);
			}
		}
	}

	void AgeBands()
	{
		for (int i = 0; i < SLOTS; i++)
		{
			if (!evLive[i]) continue;
			if ((level.maptime - evBorn[i]) < evLife[i]) continue;
			evLive[i] = false;
			// Tell the effects the band is done, so anything that accumulated
			// while it travelled has somewhere to put it back.
			NotifyBandEnd(evOrigin[i], evShared[i]);
		}

		// A Once pass ends when its LAST band has arrived -- or straight away if
		// the timing, the standing bands or the whole mod was switched off under
		// it, so nothing it held is left behind.
		if (onceLive)
		{
			int amb = StandingCount();
			bool onceOn = StandingTiming() == TM_ONCE && amb > 0
				&& RSS.GetB("rss_enabled", true);
			bool arrived = onceOn && OnceT(amb - 1, amb) >= 1.0;
			if (!onceOn || arrived)
			{
				if (arrived && AfterLookOn()) ParkOncePass(amb);
				EndOncePass();
			}
		}
		// The line belongs to Once. Switch the timing away and a looping band
		// takes its slot, so the look goes with it rather than waiting to come
		// back the next time Once is picked.
		if (parked && StandingTiming() != TM_ONCE) parked = false;

		if (pingLive)
		{
			// Not before it has finished travelling. Below speed 1 the ring
			// needs longer than the interval to cross its reach, and restarting
			// on the interval alone cut it off halfway, at full brightness.
			double every = max(RSS.GetF("rss_ping_every", 3.0), 0.1) * 35.0;
			double travel = every / max(RSS.GetF("rss_ping_speed", 1.1), 0.05);
			if ((level.maptime - pingBorn) >= max(every, travel)) pingLive = false;
		}
		if (!pingLive && RSS.GetB("rss_ping", false))
		{
			pingBorn = level.maptime;
			pingLive = true;
		}
	}

	// HOW FAR THE FRONT OF A FIRED BAND HAS TRAVELLED, in map units.
	//
	// Public and clearscope on purpose. This is the question a gameplay sweep
	// asks -- "has the front passed this monster yet" is FrontAt(i) compared
	// against the distance to it -- and it is the only thing such a feature
	// needs from here.
	clearscope double FrontAt(int i) const
	{
		if (i < 0 || i >= SLOTS || !evLive[i]) return -1.0;
		double t = (level.maptime - evBorn[i]) / max(evLife[i], 1.0);
		return clamp(t, 0.0, 1.0) * evReach[i];
	}

	// A fired band draws only in a slot nothing with priority holds. The
	// standing count can be raised, or the ping switched on, while one is
	// already out, and it used to draw straight over them.
	clearscope bool FiredDrawn(int i, int amb, bool pingOn) const
	{
		return evLive[i] && i >= amb && !(pingOn && i == PING_SLOT);
	}

	// ---- the after-look ----------------------------------------------------

	clearscope static bool AfterLookOn()
	{
		return RSS.GetB("rss_after", false);
	}

	// WHERE A FINISHED BAND WAITS, so the look it left stays and nothing of it
	// shows.
	//
	// Brightness 0 already stops its light, its recolour and its lattice in the
	// air: all three scale by the band's brightness in main.fp. The fog bow
	// does not -- it reads only the draw mode and the radius, and a band is
	// always uploaded with a draw mode. So a CROSSING is parked PARK_PAST beyond
	// its reach, where no pixel on the map is anywhere near its line and every
	// pixel is behind it. A ring, shell, bar or rising plane stays at its own
	// reach: parked further out it would grade ground its front never crossed.
	clearscope static double ParkRadius(int shape, double reach)
	{
		return IsCrossing(shape) ? reach + PARK_PAST : reach;
	}

	// THE LOOK IS ONE for every passed band, so it is pushed once, from Push,
	// which UiTick runs -- its sliders move the picture while the menu is open.
	// Only while the after-look is on: with it off this mod writes no look, so
	// another caller's passed band keeps whatever look it set.
	// LINT-UI-LIVE: rss_after rss_after_r rss_after_g rss_after_b rss_after_mix rss_after_darken rss_after_desat rss_after_soft
	// LINT-CVARS: rss_after_r rss_after_g rss_after_b
	clearscope void PushAfterLook()
	{
		Level.SetSweepPassedLook(
			RSS.RGB("rss_after", 140, 160, 220),
			RSS.GetF("rss_after_mix", 0.5),
			RSS.GetF("rss_after_darken", 0.3),
			RSS.GetF("rss_after_desat", 0.6),
			RSS.GetF("rss_after_soft", 128.0));
	}

	// ---- the push ----------------------------------------------------------

	// Every look slider on the live pages is read on this path, and UiTick runs
	// it, so they move the bands while the menu is open. Declared for menu_lint's
	// live-page check; the after-look's are beside PushAfterLook.
	// LINT-UI-LIVE: rss_ambient_count rss_ambient_speed rss_ambient_reach rss_train_speed rss_train_gap
	// LINT-UI-LIVE: rss_ambient_x rss_ambient_y rss_ambient_z rss_ping_every rss_ping_speed rss_ping_reach
	// LINT-UI-LIVE: rss_thickness rss_softness rss_intensity rss_trail rss_fade
	// LINT-UI-LIVE: rss_band_col1 rss_band_col2 rss_band_col3 rss_band_col4 rss_band_col5 rss_band_col6 rss_band_col7 rss_band_col8
	// LINT-UI-LIVE: rss_band_thick1 rss_band_thick2 rss_band_thick3 rss_band_thick4 rss_band_thick5 rss_band_thick6 rss_band_thick7 rss_band_thick8
	// LINT-UI-LIVE: rss_col_r rss_col_g rss_col_b rss_col_mix rss_col2_r rss_col2_g rss_col2_b
	// LINT-UI-LIVE: rss_fill_u rss_fill_v rss_fill_width rss_fill_soft rss_fill_gap rss_fill_air rss_fill_r rss_fill_g rss_fill_b
	// LINT-UI-LIVE: rss_fill_rotate rss_fill_drift rss_fill_major rss_fill_boost rss_fill_jitter rss_fill_flicker rss_fill_grad

	// Returns the slots it wrote, one bit each. UiTick hands back whatever was
	// held last time and is not in that set.
	clearscope int Push()
	{
		if (!Level) return 0;
		if (!RSS.GetB("rss_enabled", true)) return 0;

		// WHICH SLOTS, decided before anything is written, so a push with
		// nothing to draw touches no shared scene state at all.
		int amb = StandingCount();
		int timing = StandingTiming();
		bool standing = amb > 0 && (timing != TM_ONCE || onceLive);

		bool pingOn = RSS.GetB("rss_ping", false);
		double pingT = -1.0;
		if (pingOn && pingLive)
		{
			double every = max(RSS.GetF("rss_ping_every", 3.0), 0.1) * 35.0;
			pingT = (level.maptime - pingBorn) / every
				* max(RSS.GetF("rss_ping_speed", 1.1), 0.05);
		}
		// Nothing once it has arrived: above speed 1 it used to sit at the edge
		// of its reach until the interval came round.
		bool ping = (pingT >= 0.0 && pingT < 1.0);

		int want = 0;
		if (standing)
		{
			for (int i = 0; i < amb; i++) want |= (1 << i);
		}
		if (ping) want |= (1 << PING_SLOT);
		for (int i = 0; i < SLOTS; i++)
		{
			if (FiredDrawn(i, amb, pingOn)) want |= (1 << i);
		}

		// THE LINE A FINISHED ONCE PASS LEFT. Only under Once and only between
		// passes -- a travelling pass carries the look in its own bands -- and
		// only while nothing else draws in that slot: a fired band there wins,
		// and the look comes back when it ends.
		bool afterOn = AfterLookOn();
		bool drawPark = afterOn && parked && timing == TM_ONCE && !onceLive
			&& !(want & (1 << PARK_SLOT));
		if (drawPark) want |= (1 << PARK_SLOT);
		if (want == 0) return 0;

		// The lattice is scene-wide rather than per band -- one pattern, and
		// each band says whether it draws it. Pushed before the bands so a band
		// enabling it always has something to enable.
		Level.SetSweepFill(
			RSS.GetF("rss_fill_u", 48.0),
			RSS.GetF("rss_fill_v", 48.0),
			RSS.GetF("rss_fill_width", 3.0),
			RSS.GetF("rss_fill_soft", 1.5),
			RSS.RGB("rss_fill"),
			RSS.GetF("rss_fill_gap", 0.35));
		Level.SetSweepFillMotion(
			RSS.GetF("rss_fill_rotate", 0.0),
			RSS.GetF("rss_fill_drift", 0.0),
			RSS.GetF("rss_fill_major", 0.0),
			RSS.GetF("rss_fill_boost", 2.0),
			RSS.GetF("rss_fill_jitter", 0.0),
			RSS.GetF("rss_fill_flicker", 0.0),
			RSS.GetF("rss_fill_grad", 0.0),
			RSS.GetI("rss_fill_grad_axis", 0));
		Level.SetSweepFillAir(RSS.GetF("rss_fill_air", 0.0));
		Level.SetSweepTrail(RSS.GetF("rss_trail", 0.0));
		if (afterOn) PushAfterLook();

		int fill = RSS.GetI("rss_fill", 0);
		int draw = clamp(RSS.GetI("rss_draw", DR_ADD), DR_ADD, DR_RECOLOUR);
		double thick = RSS.GetF("rss_thickness", 26.0);
		double soft = RSS.GetF("rss_softness", 0.55);
		double inten = RSS.GetF("rss_intensity", 1.3);

		// The global origin and mode. Every band here overrides both with its
		// own via SetSweepBandAt, so this is the renderer's gate -- it draws
		// nothing while the shared mode is 0, which is what ClearSweep leaves --
		// and the count.
		Level.SetSweepOrigin(SH_RING, AnchorPoint(), SLOTS);

		// ---- standing bands, from slot 0 up ----
		if (standing)
		{
			int ashape = StandingShape();
			double pad = StandingPad(amb);
			Vector3 aorg = StandingOrigin(ashape, pad);
			double areach = StandingReach(ashape, pad);
			double aspeed = RSS.GetF("rss_ambient_speed", 0.35);

			// TRAIN TIMING -- GlowInTheDark's, carried over. One clock in map
			// units, each band `spacing` behind the one before, and the cycle
			// restarts only once the LAST band has covered the reach. Restarting
			// when the leader ran out would cut the rest of the train off
			// mid-room, which GITD did until its TrainClear learned about the
			// gaps.
			//
			// Worked out from maptime rather than stepped, so WorldTick and
			// UiTick get the same answer and it stands still while the game is
			// paused.
			double spacing = 0.0, clock = 0.0;
			if (timing == TM_TRAIN)
			{
				double tspeed = max(RSS.GetF("rss_train_speed", 128.0), 1.0);
				spacing = max(RSS.GetI("rss_train_gap", 140), 0) * tspeed / 35.0;
				double cycle = max(areach + spacing * (amb - 1), 1.0);
				clock = (level.maptime * tspeed / 35.0) % cycle;
			}

			for (int i = 0; i < amb; i++)
			{
				double r, t;
				bool darkBand = false;
				if (timing == TM_TRAIN)
				{
					r = clock - spacing * i;
					t = clamp(r / max(areach, 1.0), 0.0, 1.0);
					// A band that has not left yet is parked far off rather than
					// drawn sitting on the origin -- GITD's rule, GITD's number.
					// So is one that has ARRIVED: the lead bands wait for the
					// last to finish, and with no fade they used to run on at
					// full strength far past the reach while they waited.
					if (r < 0.0 || r > areach) r = -100000.0;
				}
				else if (timing == TM_ONCE)
				{
					// Parked before it leaves and after it arrives. The pass is
					// over once the last one has.
					//
					// With the after-look on, an ARRIVED band waits on its end
					// line instead, dark. Parked at -100000 it took its passed
					// look with it, and the look slid back to the trailing
					// band's front until the last one arrived. A band that has
					// not left stays at -100000, which grades nothing: no pixel
					// on a map is that far behind an origin.
					t = OnceT(i, amb);
					if (t >= 1.0 && afterOn)
					{
						r = ParkRadius(ashape, areach);
						t = 1.0;
						darkBand = true;
					}
					else if (t < 0.0 || t >= 1.0)
					{
						r = -100000.0;
						t = clamp(t, 0.0, 1.0);
					}
					else r = t * areach;
				}
				else
				{
					// Staggered so they do not all arrive together -- one band
					// leaving as the next arrives is what makes it read as
					// continuous.
					double phase = (level.maptime / 35.0) * aspeed + (double(i) / max(amb, 1));
					t = phase - floor(phase);
					r = t * areach;
				}

				Level.SetSweepBandAt(i, aorg, ashape);
				Level.SetSweepBand(i, r, StandingThick(i, thick), soft,
					StandingColor(i, t), darkBand ? 0.0 : inten * FadeAt(t));
				Level.SetSweepBandDraw(i, StandingDraw(i, draw));
				Level.SetSweepBandFill(i, fill);
				// Only a Once pass leaves anything behind. A looping band would
				// grade its whole reach and snap back every cycle.
				Level.SetSweepBandPassed(i, (afterOn && timing == TM_ONCE) ? 1 : 0);
			}
		}

		// ---- the ping ----
		if (ping)
		{
			Level.SetSweepBandAt(PING_SLOT, AnchorPoint(), SH_RING);
			Level.SetSweepBand(PING_SLOT, pingT * RSS.GetF("rss_ping_reach", 1100.0),
				thick, soft, BandColor(pingT), inten * FadeAt(pingT));
			Level.SetSweepBandDraw(PING_SLOT, draw);
			Level.SetSweepBandFill(PING_SLOT, fill);
			// Equipment, not a front: the ping leaves nothing behind it.
			Level.SetSweepBandPassed(PING_SLOT, 0);
		}

		// ---- fired bands ----
		for (int i = 0; i < SLOTS; i++)
		{
			if (!FiredDrawn(i, amb, pingOn)) continue;
			double t = clamp((level.maptime - evBorn[i]) / max(evLife[i], 1.0), 0.0, 1.0);
			double r = t * evReach[i];

			Level.SetSweepBandAt(i, evOrigin[i], evShape[i]);
			Level.SetSweepBand(i, r, thick, soft, BandColor(t), inten * FadeAt(t));
			Level.SetSweepBandDraw(i, draw);
			Level.SetSweepBandFill(i, fill);
			// A fired band grades what it passed only while it lives. The look
			// does not fade out with the band: it goes when the band ends.
			Level.SetSweepBandPassed(i, afterOn ? 1 : 0);
		}

		// ---- the parked line ----
		// Brightness 0, and past the far edge for a crossing -- see ParkRadius.
		// No lattice, and the shared draw mode, which at brightness 0 draws
		// nothing whichever it is.
		if (drawPark)
		{
			Level.SetSweepBandAt(PARK_SLOT, parkOrigin, parkShape);
			Level.SetSweepBand(PARK_SLOT, ParkRadius(parkShape, parkReach),
				thick, soft, BandColor(1.0), 0.0);
			Level.SetSweepBandDraw(PARK_SLOT, draw);
			Level.SetSweepBandFill(PARK_SLOT, 0);
			Level.SetSweepBandPassed(PARK_SLOT, 1);
		}

		return want;
	}

	// SWITCH OFF THE SLOTS IN `mask` -- the ones held last push and not written
	// this one. A slot handed back is a clean slot: no brightness, its origin
	// and shape returned to the shared origin, no draw mode, no lattice, which
	// is what ClearSweep leaves. With nothing held any more the trail, which is
	// scene-wide, goes back to 0 too.
	//
	// Once per slot, on the tic it stops being ours. A slot left set keeps
	// drawing whatever it last held, which is the leak this whole family has
	// been chasing; a slot zeroed every tic whether ours or not was the
	// opposite fault, and erased the weapon wheel's ring.
	clearscope void ReleaseSlots(int mask, bool all)
	{
		if (!Level || mask == 0) return;
		for (int i = 0; i < SLOTS; i++)
		{
			if (!(mask & (1 << i))) continue;
			Level.SetSweepBand(i, 0, 0, 0, 0, 0);
			Level.SetSweepBandAt(i, (0, 0, 0), 0);
			Level.SetSweepBandDraw(i, 0);
			Level.SetSweepBandFill(i, 0);
			// And its passed bit, or the slot handed back would keep grading
			// the level behind a front that no longer exists.
			Level.SetSweepBandPassed(i, 0);
		}
		if (all) Level.SetSweepTrail(0);
	}

	// The colour a band shows at progress t. One colour unless a second is
	// mixed in, in which case the band crosses into it as it travels.
	clearscope Color BandColor(double t) const
	{
		return MixToward(RSS.RGB("rss_col", 120, 200, 255), t);
	}

	// STANDING BAND i. With the per-band table off these are exactly the shared
	// values. On, each band takes its own colour, and its own thickness and
	// draw mode wherever the table says something other than 0. The second
	// colour still mixes in on top, so a table and a colour cross compose.
	//
	// The table's names are built at run time, so menu_lint is told them here.
	// LINT-CVARS: rss_band_col1 rss_band_col2 rss_band_col3 rss_band_col4 rss_band_col5 rss_band_col6 rss_band_col7 rss_band_col8
	// LINT-CVARS: rss_band_thick1 rss_band_thick2 rss_band_thick3 rss_band_thick4 rss_band_thick5 rss_band_thick6 rss_band_thick7 rss_band_thick8
	// LINT-CVARS: rss_band_draw1 rss_band_draw2 rss_band_draw3 rss_band_draw4 rss_band_draw5 rss_band_draw6 rss_band_draw7 rss_band_draw8
	clearscope Color StandingColor(int i, double t) const
	{
		if (!RSS.GetB("rss_perband", false)) return BandColor(t);
		return MixToward(RSS.Packed("rss_band_col" .. (i + 1)), t);
	}

	clearscope double StandingThick(int i, double shared) const
	{
		if (!RSS.GetB("rss_perband", false)) return shared;
		int t = RSS.GetI("rss_band_thick" .. (i + 1), 0);
		return (t > 0) ? double(t) : shared;
	}

	clearscope int StandingDraw(int i, int shared) const
	{
		if (!RSS.GetB("rss_perband", false)) return shared;
		int d = RSS.GetI("rss_band_draw" .. (i + 1), 0);
		return (d > 0) ? clamp(d, DR_ADD, DR_RECOLOUR) : shared;
	}

	// `a`, crossing into the second colour as the band travels -- or just `a`
	// when nothing is mixed in.
	clearscope Color MixToward(Color a, double t) const
	{
		double mix = clamp(RSS.GetF("rss_col_mix", 0.0), 0.0, 1.0);
		if (mix <= 0.0) return a;

		Color b = RSS.RGB("rss_col2", 255, 90, 160);
		double f = clamp(t, 0.0, 1.0) * mix;
		return Color(255,
			int(a.r + (b.r - a.r) * f),
			int(a.g + (b.g - a.g) * f),
			int(a.b + (b.b - a.b) * f));
	}

	// Bands fade out over the tail of their travel rather than stopping at
	// full brightness, which reads as the band being switched off.
	clearscope double FadeAt(double t) const
	{
		double fade = clamp(RSS.GetF("rss_fade", 0.35), 0.0, 0.95);
		if (fade <= 0.0) return 1.0;
		double start = 1.0 - fade;
		if (t <= start) return 1.0;
		return clamp(1.0 - (t - start) / fade, 0.0, 1.0);
	}

	// ---- what fires one ----------------------------------------------------

	// The shape a fired band takes. ONE reading for every trigger that uses
	// rss_ev_shape, so one menu setting cannot give a sweep off a kill and a
	// rising plane off a rocket.
	clearscope int EventShape() const
	{
		return clamp(RSS.GetI("rss_ev_shape", SH_RING), SH_RING, SH_SWEEPNY);
	}

	override void WorldThingDied(WorldEvent e)
	{
		if (!RSS.GetB("rss_ev_kill", true)) return;
		if (!e || !e.Thing || !e.Thing.bIsMonster) return;
		if (!KillQualifies(e.Thing)) return;
		Fire(e.Thing.pos, EventShape());
	}

	// WHICH KILLS ARE WORTH A SWEEP.
	//
	// Empty class name means any monster. Naming one means that class and
	// anything descended from it, so "RS_BaronOfHell" catches every colour of
	// baron without listing thirteen of them.
	//
	// The tier floor is read as an INVENTORY ITEM, not by calling into the
	// monster mod -- FindInventory on a class looked up from a string, so this
	// needs no reference to anything RS_Main defines and simply finds nothing
	// when that mod is absent. A floor above 0 therefore means "only tiered
	// monsters", automatically.
	//
	// IT ONLY SEES THE TOKEN. Monsters that tier through RS_Zom.SetTier carry
	// RS_ZomTierToken; RS_MonsterMaster keeps its tier in a field this mod
	// cannot read without naming the class, so a floor above 0 skips those.
	// The fix belongs in RS_Main -- mirror the tier into the token -- not in a
	// compile-time link from here.
	bool KillQualifies(Actor t) const
	{
		String want = RSS.GetS("rss_ev_class", "");
		if (want.Length() > 0)
		{
			Class<Actor> c = want;
			if (!c || !(t is c)) return false;
		}

		int floorTier = RSS.GetI("rss_ev_tier_min", 0);
		if (floorTier > 0)
		{
			// RESOLVED AT RUNTIME. CountInv takes a class NAME and validates it
			// while compiling, so naming a class no loaded mod defines is a
			// hard parse error -- which would have made this mod depend on the
			// monster mod again, by the back door. Going through a String into
			// a Class<Inventory> is the same lookup done at runtime: null when
			// that mod is absent, and then there is no tier to test.
			String tokName = "RS_ZomTierToken";
			Class<Inventory> tok = tokName;
			if (!tok) return false;
			let inv = t.FindInventory(tok);
			if (!inv || inv.Amount < floorTier) return false;
		}

		// BOSSES ONLY.
		//
		// Three independent ways a thing can be a boss, and they do not agree
		// with each other, so all three count:
		//
		//   bBoss        the actor flag. Cyberdemon, Mastermind, and anything
		//                a mod marked itself.
		//   bBossDeath   calls A_BossDeath -- the thing whose death opens a
		//                door or ends a map. Often set without +BOSS.
		//   health       a plain size test, because a colour-tier boss is
		//                frequently neither flagged nor scripted and is simply
		//                enormous. Off at 0.
		//
		// A tier floor and this can be combined: bosses at tier 10 and up.
		if (RSS.GetB("rss_ev_bossonly", false))
		{
			int bigAt = RSS.GetI("rss_ev_boss_health", 1500);
			bool isBoss = t.bBoss || t.bBossDeath
				|| (bigAt > 0 && t.SpawnHealth() >= bigAt);
			if (!isBoss) return false;
		}

		return true;
	}

	override void WorldThingDamaged(WorldEvent e)
	{
		if (!e || !e.Thing) return;

		// One blast is one band. WorldThingDamaged fires once per thing hurt,
		// and a rocket into a pack hurts all of them at the same point on the
		// same tic -- without this a crowd claims every slot at once. Same trap
		// RS_Fog fell into with its ignite hook.
		if (RSS.GetB("rss_ev_explode", true) && e.DamageIsRadius)
		{
			if (e.Inflictor == lastBlastSrc && level.maptime == lastBlastTic) return;
			lastBlastSrc = e.Inflictor;
			lastBlastTic = level.maptime;
			Fire(e.DamagePosition, EventShape());
			return;
		}

		// LOCAL. consoleplayer is a different player on every machine, so this
		// band exists on one of them only, and in a netgame it runs the
		// look-only effects alone -- see NETPLAY at the top.
		if (RSS.GetB("rss_ev_hurt", false) && e.Thing.player
			&& e.Thing.player == players[consoleplayer])
		{
			Fire(e.Thing.pos, SH_SHELL, false);
		}
	}

	private Actor lastBlastSrc;
	private int lastBlastTic;
}
