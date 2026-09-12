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
//   slots 0 .. ambientCount-1   standing bands
//   slot  7                     the ping, when it is on
//   the rest, from 6 downward   fired bands, newest first
//
// Ambient wins ties because it is the one you notice missing. Turn the ambient
// count up to eight and events have nowhere to go -- the menu says so rather
// than silently dropping them.
//
// A FIRED BAND IS A TRACKED OBJECT, not just a push to the shader. It keeps its
// origin, its birth time and its speed on this side, so "where is the front
// now" and "has it passed this actor yet" are answerable questions. Nothing
// uses that yet beyond drawing, and it is the hook a gameplay sweep would hang
// on -- a band that re-tiers what it washes over needs exactly this and nothing
// more.

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
	const DR_ADD    = 1;
	const DR_LIFT   = 2;
	const DR_CRUSH  = 3;

	// ---- fired bands -------------------------------------------------------
	//
	// Parallel arrays rather than a class per band: there are at most eight,
	// they are pure data, and an array of objects would mean allocation on
	// every kill.
	private Vector3 evOrigin[SLOTS];
	private double  evBorn[SLOTS];     // level.maptime when it was fired
	private double  evLife[SLOTS];     // in tics
	private double  evReach[SLOTS];
	private int     evShape[SLOTS];
	private bool    evLive[SLOTS];
	// Where the front was LAST tic. The crossing test is a threshold -- behind
	// this thing then, past it now -- so it needs both edges.
	private double  evPrevFront[SLOTS];

	// The ping.
	private double pingBorn;
	private bool   pingLive;

	// Where the standing bands and the ping are centred. Resolved in play
	// scope because "follows you" reads the world; the look is pushed from
	// clearscope so the menu moves the picture while the game is paused.
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

	// How far a band of this shape must travel to cross the whole map, and
	// where it has to start. Signed shapes only -- everything else keeps its
	// own origin and its own reach.
	double SweepSpan(int shape) const
	{
		if (shape == SH_SWEEPX || shape == SH_SWEEPNX) return mapMaxX - mapMinX;
		if (shape == SH_SWEEPY || shape == SH_SWEEPNY) return mapMaxY - mapMinY;
		return 0.0;
	}

	// How much map is left in front of a point, for a sweep that starts
	// somewhere other than the edge.
	double SpanFrom(int shape, Vector3 at) const
	{
		if (shape == SH_SWEEPX)  return max(mapMaxX - at.x, 1.0);
		if (shape == SH_SWEEPNX) return max(at.x - mapMinX, 1.0);
		if (shape == SH_SWEEPY)  return max(mapMaxY - at.y, 1.0);
		if (shape == SH_SWEEPNY) return max(at.y - mapMinY, 1.0);
		return 1.0;
	}

	Vector3 SweepStart(int shape) const
	{
		double z = 0;
		if (shape == SH_SWEEPX)  return (mapMinX, (mapMinY + mapMaxY) * 0.5, z);
		if (shape == SH_SWEEPNX) return (mapMaxX, (mapMinY + mapMaxY) * 0.5, z);
		if (shape == SH_SWEEPY)  return ((mapMinX + mapMaxX) * 0.5, mapMinY, z);
		if (shape == SH_SWEEPNY) return ((mapMinX + mapMaxX) * 0.5, mapMaxY, z);
		return anchor;
	}

	override void WorldLoaded(WorldEvent e)
	{
		MeasureMap();
		// The built-ins register themselves. Each is inert until its own switch
		// is on, so registering them all costs one array walk per crossing and
		// nothing else.
		{
			let f1 = new("RSS_FxFogRipple"); f1.id = "fog";      Register(f1);
			let f2 = new("RSS_FxRecolour");  f2.id = "recolour"; Register(f2);
			let f3 = new("RSS_FxRouse");     f3.id = "rouse";    Register(f3);
			let f4 = new("RSS_FxCrossed");   f4.id = "crossed";  Register(f4);
			let f5  = new("RSS_FxGlow");    f5.id  = "glow";    Register(f5);
			let f6  = new("RSS_FxLight");   f6.id  = "light";   Register(f6);
			let f7  = new("RSS_FxFogTint"); f7.id  = "fogtint"; Register(f7);
			let f8  = new("RSS_FxDarken");  f8.id  = "darken";  Register(f8);
			let f9  = new("RSS_FxDesat");   f9.id  = "desat";   Register(f9);
			let f10 = new("RSS_FxDecor");   f10.id = "decor";   Register(f10);
		}

		SyncPreset();
		for (int i = 0; i < SLOTS; i++) evLive[i] = false;
		pingLive = false;
		anchorValid = false;
		ResolveAnchor();
		Push();
	}

	override void WorldUnloaded(WorldEvent e)
	{
		// The bands are level state, not mod state. Leaving them set means the
		// next map opens wearing the last one.
		if (Level) Level.ClearSweep();
	}

	override void WorldTick()
	{
		SyncPreset();
		ResolveAnchor();
		AgeBands();
		Crossings();
		Push();
	}

	// The playsim stops while the menu is up, so WorldTick alone would freeze
	// the picture exactly while the slider meant to change it is dragged. Every
	// sweep setter is clearscope for this reason.
	//
	// Bands are NOT aged from here. Ageing is the passage of time in the world,
	// and a fired band creeping outward while the game is paused would be
	// wrong. The anchor is not resolved here either -- it reads the world.
	override void UiTick()
	{
		SyncPreset();
		Push();
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

	void ResolveAnchor()
	{
		int mode = RSS.GetI("rss_ambient_org", 1);
		if (mode == 1)
		{
			let pmo = players[consoleplayer].camera;
			if (pmo)
			{
				anchor = pmo.pos;
				anchorValid = true;
				return;
			}
		}
		else if (mode == 2)
		{
			anchor = (RSS.GetF("rss_ambient_x"), RSS.GetF("rss_ambient_y"),
				RSS.GetF("rss_ambient_z"));
			anchorValid = true;
			return;
		}
		else if (mode == 3)
		{
			anchor = (mapCentre.x, mapCentre.y, 0);
			anchorValid = true;
			return;
		}
		anchor = (0, 0, 0);
		anchorValid = true;
	}

	// ---- firing ------------------------------------------------------------

	// Claim a slot for a fired band. Counts DOWN from just under the ping, so
	// the standing bands at the bottom are never disturbed, and recycles the
	// oldest when the allowance is full -- a busy room should show the most
	// recent kills rather than refusing to show any.
	void Fire(Vector3 at, int shape)
	{
		if (!RSS.GetB("rss_enabled", true)) return;

		int allow = clamp(RSS.GetI("rss_ev_slots", 4), 0, SLOTS);
		if (allow <= 0) return;

		int lowest = clamp(RSS.GetI("rss_ambient_count", 2), 0, SLOTS);
		if (!RSS.GetB("rss_ambient", true)) lowest = 0;

		int top = RSS.GetB("rss_ping", false) ? PING_SLOT - 1 : PING_SLOT;
		int used = 0, pick = -1;
		double oldest = 1e30;
		int oldestIdx = -1;

		for (int i = top; i >= lowest; i--)
		{
			if (!evLive[i]) { if (pick < 0) pick = i; continue; }
			used++;
			if (evBorn[i] < oldest) { oldest = evBorn[i]; oldestIdx = i; }
		}

		if (used >= allow) pick = oldestIdx;
		if (pick < 0) return;

		bool crossing = (shape >= SH_SWEEPX && shape <= SH_SWEEPNY);

		evOrigin[pick] = at;
		evBorn[pick] = level.maptime;
		evLife[pick] = max(RSS.GetF("rss_ev_life", 1.1), 0.05) * 35.0;
		// A signed shape fired from a thing crosses the rest of the map from
		// where that thing was standing. Anything else uses its own reach.
		evReach[pick] = crossing ? SpanFrom(shape, at) : RSS.GetF("rss_ev_reach", 700.0);
		evShape[pick] = shape;
		evLive[pick] = true;
		evPrevFront[pick] = 0.0;
	}

	// ---- what a band does to what it passes --------------------------------
	//
	// Registered effects live on RSS_Registry, a static handler, because
	// ZScript has no static data members and the list has to outlive any one
	// level -- a mod registers once and expects it to stick.
	static void Register(RSS_Effect fx)
	{
		let reg = RSS_Registry.Get();
		if (reg) reg.Add(fx);
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
		return (at.xy - org.xy).Length();
	}

	// THE FRONTIER. Everything the front reached since last tic, once each.
	//
	// A threshold rather than a containment test: inside-the-band would fire
	// every tic for as long as the band covered a thing, and spawn-time would
	// treat the whole level as simultaneous and throw away the wave entirely.
	//
	// Only bands that carry an effect do this walk. A purely decorative sweep
	// -- which is most of them, and all the ambient ones -- costs nothing here,
	// so the per-tic price is paid only by a band that is actually changing
	// something.
	void Crossings()
	{
		let reg = RSS_Registry.Get();
		if (!reg || reg.effects.Size() == 0) return;
		if (!RSS.GetB("rss_fx", false)) return;

		bool doSectors = RSS.GetB("rss_fx_sectors", true);
		bool doActors = RSS.GetB("rss_fx_actors", true);

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
			Color tint = BandColor(prog);

			if (doSectors)
			{
				for (int si = 0; si < Level.Sectors.Size(); si++)
				{
					let sec = Level.Sectors[si];
					Vector3 c = (sec.centerspot.x, sec.centerspot.y,
						sec.floorplane.ZatPoint(sec.centerspot));
					double d = BandDistance(evShape[i], evOrigin[i], c);
					if (d < prev || d >= front) continue;
					for (int k = 0; k < reg.effects.Size(); k++)
						if (reg.effects[k]) reg.effects[k].OnSector(sec, evOrigin[i], front, tint);
				}
			}

			if (doActors)
			{
				let it = ThinkerIterator.Create("Actor");
				Actor a;
				while (a = Actor(it.Next()))
				{
					if (!a) continue;
					double d = BandDistance(evShape[i], evOrigin[i], a.pos);
					if (d < prev || d >= front) continue;
					for (int k = 0; k < reg.effects.Size(); k++)
						if (reg.effects[k]) reg.effects[k].OnActor(a, evOrigin[i], front, tint);
				}
			}
		}
	}

	void AgeBands()
	{
		let reg = RSS_Registry.Get();
		for (int i = 0; i < SLOTS; i++)
		{
			if (!evLive[i]) continue;
			if ((level.maptime - evBorn[i]) < evLife[i]) continue;
			evLive[i] = false;
			// Tell the effects the band is done, so anything that accumulated
			// while it travelled has somewhere to put it back.
			if (reg)
				for (int k = 0; k < reg.effects.Size(); k++)
					if (reg.effects[k]) reg.effects[k].OnBandEnd(evOrigin[i]);
		}

		if (pingLive)
		{
			double every = max(RSS.GetF("rss_ping_every", 3.0), 0.1) * 35.0;
			if ((level.maptime - pingBorn) >= every) pingLive = false;
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
		return clamp(t, 0.0, 1.0) * evReach[i] * RSS.GetF("rss_ev_speed", 1.0);
	}

	// ---- the push ----------------------------------------------------------

	clearscope void Push()
	{
		if (!Level) return;

		if (!RSS.GetB("rss_enabled", true))
		{
			Level.ClearSweep();
			return;
		}

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

		int fill = RSS.GetI("rss_fill", 0);
		int draw = clamp(RSS.GetI("rss_draw", DR_ADD), DR_ADD, DR_CRUSH);
		double thick = RSS.GetF("rss_thickness", 26.0);
		double soft = RSS.GetF("rss_softness", 0.55);
		double inten = RSS.GetF("rss_intensity", 1.3);

		// The global origin and mode. Each band overrides both with its own via
		// SetSweepBandAt, so this is the fallback and the count.
		Level.SetSweepOrigin(SH_RING, anchor, SLOTS);

		int live = 0;

		// ---- standing bands, from slot 0 up ----
		int amb = RSS.GetB("rss_ambient", true)
			? clamp(RSS.GetI("rss_ambient_count", 2), 0, SLOTS) : 0;
		int ashape = clamp(RSS.GetI("rss_ambient_shape", SH_RING), SH_RING, SH_RISE);
		double areach = RSS.GetF("rss_ambient_reach", 900.0);
		double aspeed = RSS.GetF("rss_ambient_speed", 0.35);

		// A SIGNED SHAPE CROSSES THE MAP. It ignores the origin setting and the
		// reach slider on purpose: a sweep that stops halfway, or starts in the
		// middle, is not a sweep. The geometry decides both.
		bool crossing = (ashape >= SH_SWEEPX && ashape <= SH_SWEEPNY);
		Vector3 aorg = anchor;
		if (crossing)
		{
			// FROM THE EDGE, or FROM WHERE YOU ARE.
			//
			// From the edge is the plain reading: one front crossing the whole
			// map. From you is the other one worth having -- the front starts
			// at your feet and travels outward, so the level changes away from
			// you rather than arriving at you, and the reach is only as far as
			// it still has map to cross.
			if (RSS.GetI("rss_ambient_org", 1) == 1 && anchorValid)
			{
				aorg = anchor;
				areach = SpanFrom(ashape, anchor);
			}
			else
			{
				aorg = SweepStart(ashape);
				double span = SweepSpan(ashape);
				if (span > 1.0) areach = span;
			}
		}

		// TRAIN TIMING -- GlowInTheDark's, carried over. One clock in map units,
		// each band `spacing` behind the one before, and the cycle restarts only
		// once the LAST band has covered the reach. Restarting when the leader
		// ran out would cut the rest of the train off mid-room, which GITD did
		// until its TrainClear learned about the gaps.
		//
		// Worked out from maptime rather than stepped, so WorldTick and UiTick
		// get the same answer and it stands still while the game is paused.
		bool train = (RSS.GetI("rss_ambient_timing", 0) == 1);
		double spacing = 0.0, clock = 0.0;
		if (train && amb > 0)
		{
			double tspeed = max(RSS.GetF("rss_train_speed", 128.0), 1.0);
			spacing = max(RSS.GetI("rss_train_gap", 140), 0) * tspeed / 35.0;
			double cycle = max(areach + spacing * (amb - 1), 1.0);
			clock = (level.maptime * tspeed / 35.0) % cycle;
		}

		for (int i = 0; i < amb; i++)
		{
			double r, t;
			if (train)
			{
				r = clock - spacing * i;
				t = clamp(r / max(areach, 1.0), 0.0, 1.0);
				// A band that has not left yet is parked far off rather than
				// drawn sitting on the origin. GITD's rule, GITD's number.
				if (r < 0.0) r = -100000.0;
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
				StandingColor(i, t), inten * FadeAt(t));
			Level.SetSweepBandDraw(i, StandingDraw(i, draw));
			Level.SetSweepBandFill(i, fill);
			live++;
		}

		// ---- the ping ----
		if (RSS.GetB("rss_ping", false))
		{
			double every = max(RSS.GetF("rss_ping_every", 3.0), 0.1) * 35.0;
			double t = clamp((level.maptime - pingBorn) / every, 0.0, 1.0);
			t = clamp(t * RSS.GetF("rss_ping_speed", 1.1), 0.0, 1.0);

			Level.SetSweepBandAt(PING_SLOT, anchor, SH_RING);
			Level.SetSweepBand(PING_SLOT, t * RSS.GetF("rss_ping_reach", 1100.0),
				thick, soft, BandColor(t), inten * FadeAt(t));
			Level.SetSweepBandDraw(PING_SLOT, draw);
			Level.SetSweepBandFill(PING_SLOT, fill);
			live++;
		}

		// ---- fired bands ----
		for (int i = 0; i < SLOTS; i++)
		{
			if (!evLive[i]) continue;
			double t = clamp((level.maptime - evBorn[i]) / max(evLife[i], 1.0), 0.0, 1.0);
			double r = t * evReach[i] * RSS.GetF("rss_ev_speed", 1.0);

			Level.SetSweepBandAt(i, evOrigin[i], evShape[i]);
			Level.SetSweepBand(i, r, thick, soft, BandColor(t), inten * FadeAt(t));
			Level.SetSweepBandDraw(i, draw);
			Level.SetSweepBandFill(i, fill);
			live++;
		}

		// Every slot that is not carrying a band is switched off explicitly.
		// A slot left set keeps drawing whatever it last held, which is the
		// leak this whole family has been chasing all day.
		for (int i = 0; i < SLOTS; i++)
		{
			bool used = (i < amb)
				|| (i == PING_SLOT && RSS.GetB("rss_ping", false))
				|| evLive[i];
			if (!used) Level.SetSweepBand(i, 0, 0, 0, 0, 0);
		}
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
		return (d > 0) ? clamp(d, DR_ADD, DR_CRUSH) : shared;
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

	override void WorldThingDied(WorldEvent e)
	{
		if (!RSS.GetB("rss_ev_kill", true)) return;
		if (!e || !e.Thing || !e.Thing.bIsMonster) return;
		if (!KillQualifies(e.Thing)) return;
		Fire(e.Thing.pos, clamp(RSS.GetI("rss_ev_shape", SH_RING), SH_RING, SH_SWEEPNY));
	}

	// WHICH KILLS ARE WORTH A SWEEP.
	//
	// Empty class name means any monster. Naming one means that class and
	// anything descended from it, so "RS_BaronOfHell" catches every colour of
	// baron without listing thirteen of them.
	//
	// The tier floor is read as an INVENTORY COUNT, not by calling into the
	// monster mod -- CountInv takes a class name, so this needs no reference to
	// anything RS_Main defines and is simply 0 when that mod is absent. A floor
	// above 0 therefore means "only tiered monsters", automatically.
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
			Fire(e.DamagePosition,
				clamp(RSS.GetI("rss_ev_shape", SH_RING), SH_RING, SH_RISE));
			return;
		}

		if (RSS.GetB("rss_ev_hurt", false) && e.Thing.player
			&& e.Thing.player == players[consoleplayer])
		{
			Fire(e.Thing.pos, SH_SHELL);
		}
	}

	private Actor lastBlastSrc;
	private int lastBlastTic;
}
