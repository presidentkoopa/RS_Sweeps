// RS_Sweeps -- WHAT A BAND DOES TO WHAT IT PASSES.
//
// The band is a moving frontier. Everything it crosses should be acted on
// exactly ONCE, at the moment the front reaches it -- not while it is inside
// the band, which would fire every tic for as long as the band was over it, and
// not when the band is spawned, which would treat the whole level as
// simultaneous and throw away the entire point of a wave.
//
// So the crossing test is a THRESHOLD, not a containment test: the front was
// behind this thing last tic and is past it now. That is one event per thing
// per band, in the order the wave reaches them, which is what makes a sweep
// read as travelling rather than as a level-wide toggle with a light on top.
//
// WHY THIS IS A CLASS AND NOT A SWITCH STATEMENT.
//
// The effects wanted already span darkness, glow, fog, monsters and
// decorations, and the list is explicitly open. A switch in the handler would
// mean every new effect edits the handler, and a second mod could never add one
// at all. An effect is an object with a handful of hooks; the handler walks
// whatever is registered and knows nothing about any of them.
//
// Register from any mod, with an id of your own:
//
//   class MyEffect : RSS_Effect
//   {
//       override void OnActor(Actor a, Vector3 origin, double front, Color tint) { ... }
//   }
//   RSS_Handler.Register(new("MyEffect"), "mymod.myeffect");
//
// The id is required. Registering again under the same id replaces the old
// copy, which is what stops a map load stacking a second one -- and it is why
// an effect with no id is refused rather than allowed to replace another mod's.
//
// NEVER WRITE A SERVER CVAR PER SECTOR. A server write is queued to the network
// and only lands after it round-trips, so every sector in the tic reads the old
// value back, and a front crossing dozens of sectors queues dozens of writes.
// Gather in OnSector, publish once in OnTicDone, through a nosave cvar the
// other mod reads.
//
// PLAY SCOPE, all of it. Crossing reads the world and the effects change it.

class RSS_Effect play
{
	// A name, so a mod can find and replace its own registration rather than
	// stacking a second copy on every map load.
	String id;

	// Called once per actor the front reaches. `origin` is where the band was
	// fired from and `front` is how far it has travelled, so an effect that
	// wants to scale with distance has what it needs without recomputing it.
	virtual void OnActor(Actor a, Vector3 origin, double front, Color tint) {}

	// Called once per sector the front reaches. Sectors are tested at their
	// centre, so a very large sector fires when its middle is crossed rather
	// than its near edge -- the alternative is testing every vertex, which is
	// a lot of work for a boundary nobody can see.
	virtual void OnSector(Sector s, Vector3 origin, double front, Color tint) {}

	// Called once when a band finishes, whether it ran out of life or was
	// recycled. Somewhere to put "and now put it all back". Other bands may
	// still be out -- RSS_Handler.AnyBandLive() says whether this was the last.
	virtual void OnBandEnd(Vector3 origin) {}

	// Called once per band per tic, BEFORE that band's sectors and actors,
	// whenever its front moved and the level is being walked. Somewhere to
	// start a per-band budget, or to write something once per band rather than
	// once per sector.
	virtual void OnFrontMoved(Vector3 origin, double front, Color tint) {}

	// Called once every tic, after every band has been walked and every finished
	// band has ended -- on tics when nothing was walked too. Somewhere to publish
	// what the crossings gathered in ONE write, and to let go of something the
	// player switched off in the middle of a band.
	virtual void OnTicDone() {}

	// The map is ending, or a new one is starting. Put back anything that would
	// otherwise outlive it: engine state and cvars are not per map, and a band
	// the map change cut short never gets its OnBandEnd.
	virtual void ResetForMap() {}

	// WHETHER THIS EFFECT ACTS ON SECTORS, OR ACTORS, AT ALL RIGHT NOW. The
	// handler walks every sector and every actor only while some effect says
	// yes, so a band with every switch off costs nothing. True unless
	// overridden, so an effect from another mod is walked exactly as it always
	// was.
	virtual bool WantsSectors() { return true; }
	virtual bool WantsActors() { return true; }

	// WHETHER THIS EFFECT ONLY CHANGES WHAT IS DRAWN. True for an effect that
	// touches nothing the playsim reads -- glow, fog, outlines, a cvar another
	// mod draws with. False for one that changes the game: a monster's target
	// or tier, a sector's light level, anything spawned or damaged.
	//
	// NETPLAY. Not every band is the same on every machine. A "follows you"
	// standing band leaves from each player's own camera, and "when YOU are
	// hurt" fires on one machine only. In a multiplayer game an effect that is
	// not look-only hears only the bands every player shares -- fired from a
	// kill or an explosion, or a Once pass whose origin is not a camera -- and
	// is skipped for the others: OnFrontMoved, OnSector, OnActor and OnBandEnd
	// alike. OnTicDone and ResetForMap are not per band and always run. In
	// single player every effect hears every band, exactly as before.
	//
	// False unless overridden, so an effect from another mod is treated as
	// gameplay: the worst that does to a look effect is miss a band in a
	// netgame, where the other way round a gameplay effect would desync it.
	virtual bool LookOnly() { return false; }
}

// ---------------------------------------------------------------------------
// The built-ins. Each is a proof that the frontier works and a useful effect in
// its own right; none of them is the interesting one, which is monster tiering
// and is deliberately not guessed at here.
// ---------------------------------------------------------------------------

// A ripple pushed into the fog as the front passes, so mist reacts to a sweep
// instead of ignoring it. Skipped entirely when RS_Fog is not loaded.
class RSS_FxFogRipple : RSS_Effect
{
	// A FEW PER BAND PER TIC, not one per sector. The engine keeps a small
	// shared pool of disturbances and recycles the oldest, so a fast front
	// crossing thirty sectors in a tic refilled the whole pool every tic, and
	// RS_Fog's own wake, death and blast ripples vanished the moment they were
	// made.
	// PER TIC, ACROSS EVERY BAND -- not per band. The pool is 32 slots and the
	// oldest is recycled, and RS_Fog throttles itself hard against it (one
	// wader pick every rsf_wader_every tics, 6 by default). Three per band was
	// fine for one band and starved that throttle at eight: 24 of 32 slots
	// refilled every tic, and the player's own wake, the death ripples and the
	// explosion flashes vanished as fast as they were made.
	const RIPPLES_PER_TIC = 6;
	private int rippled;

	override bool WantsSectors() { return RSS.GetB("rss_fx_fog", false) && RSS.HasFog(); }
	override bool WantsActors() { return false; }
	// The disturbance pool is shader input only.
	override bool LookOnly() { return true; }

	// Not reset per band any more -- the budget is the tic's, so eight bands
	// share what one band used to have to itself.
	override void OnTicDone()
	{
		rippled = 0;
	}

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_fog", false)) return;
		if (rippled >= RIPPLES_PER_TIC) return;
		rippled++;

		Vector3 at = (s.centerspot.x, s.centerspot.y, s.floorplane.ZatPoint(s.centerspot));
		// Mode 1 is a travelling ring -- the same disturbance a death makes,
		// so a swept room and a killed monster disturb the mist the same way.
		Level.FogDisturb(at.x, at.y, at.z,
			RSS.GetF("rss_fx_fog_radius", 160.0),
			RSS.GetF("rss_fx_fog_strength", 0.7),
			RSS.GetF("rss_fx_fog_speed", 200.0),
			RSS.GetF("rss_fx_fog_life", 0.8), 1);
	}
}

// Re-roll the sector's glow colour as the front passes, so a sweep repaints the
// level behind itself rather than merely lighting it. This is the one that
// makes a wave feel like it CHANGED something.
//
// It writes the sector glow directly rather than going through GlowInTheDark,
// because the two mods do not know about each other and a sweep that only
// worked with GITD loaded would be a worse thing to have built. It leaves a
// claim on the flats it painted, so GITD's own repaint passes them by -- see
// RSS_SectorClaim.
class RSS_FxRecolour : RSS_Effect
{
	override bool WantsSectors() { return RSS.GetB("rss_fx_recolour", false); }
	override bool WantsActors() { return false; }
	// Sector glow is render state, and its claim markers are client-side.
	override bool LookOnly() { return true; }

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_recolour", false)) return;

		// THE SWEEP'S OWN COLOUR, not a roll. The band that lit the room this
		// colour leaves it this colour -- which is what makes a sweep read as
		// having CHANGED something rather than having flashed over it.
		Color c = tint;

		double reach = RSS.GetF("rss_fx_recolour_reach", 140.0);
		s.SetFlatGlowColor(Sector.floor, c);
		s.SetFlatGlowColor(Sector.ceiling, c);
		// The far colour too -- see RSS_FxGlow.
		s.SetFlatGlowColorFar(Sector.floor, c);
		s.SetFlatGlowColorFar(Sector.ceiling, c);
		s.SetFlatGlowHeight(Sector.floor, reach);
		s.SetFlatGlowHeight(Sector.ceiling, reach * 0.7);

		RSS_Handler.ClaimSector(s, RSS_SectorClaim.PART_FLATS, RSS_SectorClaim.BY_RECOLOUR);
	}

	// Switched off -- this effect, the Effects page, or the whole mod -- and the
	// flats it painted are handed back. The colour stays until something else
	// paints there; with GITD loaded that is GITD's next look at the map.
	override void OnTicDone()
	{
		if (RSS.GetB("rss_enabled", true) && RSS.GetB("rss_fx", false)
			&& RSS.GetB("rss_fx_recolour", false)) return;
		RSS_Handler.ReleaseClaims(RSS_SectorClaim.BY_RECOLOUR);
	}
}

// Wake what the front reaches. A sweep that alerts the level is a gameplay
// event rather than a decoration, and it is the smallest honest example of the
// frontier changing the game rather than the picture.
//
// GAMEPLAY, so in a netgame it hears only the bands every player shares -- see
// RSS_Effect.LookOnly.
//
// THE NEAREST PLAYER, NEVER consoleplayer. consoleplayer is a different player
// on every machine, so a monster woken toward "you" hunted a different player
// on each peer and the game desynced. Player positions are playsim state, the
// same everywhere, so the nearest one is the same answer on every machine: a
// living player beats a dead one, and a tie goes to the lower player number.
// In single player the only player is the nearest, so nothing there changes.
class RSS_FxRouse : RSS_Effect
{
	override bool WantsSectors() { return false; }
	override bool WantsActors() { return RSS.GetB("rss_fx_rouse", false); }

	override void OnActor(Actor a, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_rouse", false)) return;
		if (!a || !a.bIsMonster || a.health <= 0) return;
		if (a.target != null) return;

		let pmo = NearestPlayer(a);
		if (pmo) a.target = pmo;
	}

	// Walked in player order with a strict comparison, so the pick depends on
	// nothing but the players' own positions, health and numbers.
	static Actor NearestPlayer(Actor from)
	{
		Actor best = null;
		bool bestAlive = false;
		double bestDist = 0.0;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i]) continue;
			let mo = players[i].mo;
			if (!mo) continue;
			bool alive = mo.health > 0;
			double d = from.Distance3D(mo);
			if (best)
			{
				if (bestAlive && !alive) continue;
				if (bestAlive == alive && d >= bestDist) continue;
			}
			best = mo;
			bestAlive = alive;
			bestDist = d;
		}
		return best;
	}
}

// ---------------------------------------------------------------------------
// THE COLOUR IS THE PAYLOAD.
//
// A sweep carries a colour and every effect reads that ONE colour into its own
// domain: a blue sweep makes blue fog, blue glow and blue monsters. Which of
// them it touches is the player's choice -- one, some, or all. Without that,
// a sweep would be several unrelated things happening at once instead of one
// thing arriving.
//
// THE LADDER LIVES WHERE THE MONSTERS LIVE. An earlier draft kept a copy of the
// tier colours here so this file could pick a rung itself. Two copies of the
// same table in two mods is a drift waiting to happen, and it also put monster
// knowledge in a lighting mod. The colour is handed over through
// Actor.OnSweepCrossed and whoever owns the ladder decides what it means.
// ---------------------------------------------------------------------------

// THE ONE THIS WAS BUILT FOR -- WITHOUT KNOWING WHAT A MONSTER IS.
//
// This mod draws light. It has no business holding a reference to a monster
// class, and an earlier draft of this file did exactly that, which made a
// LIGHTING mod fail to compile unless a MONSTER mod was loaded. That was wrong.
//
// Actor.OnSweepCrossed is the engine hook that fixes it: empty on Actor, so it
// costs nothing and works on every actor in the game, and overridden by whoever
// cares. RS_Sweeps calls it on what the front reaches and never asks what the
// thing is. A monster mod overrides it and re-tiers. Neither mod has to know
// the other exists, and either one loads alone.
//
// GAMEPLAY: a retier changes the monster. So in a netgame the hook is called
// only for the bands every player shares -- see RSS_Effect.LookOnly -- and an
// override may rely on that.
class RSS_FxCrossed : RSS_Effect
{
	override bool WantsSectors() { return false; }

	// Skipped outright when nothing that overrides the hook is loaded, so a
	// sweep with no monster mod present does not walk every actor in the level
	// to call an empty function on each of them.
	override bool WantsActors()
	{
		return RSS.GetB("rss_fx_crossed", true)
			&& (RSS.HasMonsterTiers() || RSS.GetB("rss_fx_crossed_always", false));
	}

	override void OnActor(Actor a, Vector3 origin, double front, Color tint)
	{
		if (!a || !WantsActors()) return;
		a.OnSweepCrossed(origin, front, tint);
	}
}

// GLOW. Repaint the sector the front crosses in the sweep's colour -- both the
// wall glow it throws and its own flat-edge glow. This is the one that makes a
// sweep read as having CHANGED the room rather than lit it for a moment.
//
// THE FAR COLOUR IS WRITTEN TOO. Each glow ramps from its colour into a far
// colour, and GlowInTheDark derives that far colour from its own hue. Left
// alone, a swept room's new glow ramped straight back into the old room's
// colour.
//
// AND THE SECTOR IS CLAIMED. GITD repaints the whole map whenever one of its
// settings moves, and re-reads lights and flats about once a second; both used
// to take the sweep's colour straight back off. The claim is what GITD skips --
// see RSS_SectorClaim. Only the parts actually painted are claimed, so a sweep
// set to leave the walls alone leaves them GITD's.
class RSS_FxGlow : RSS_Effect
{
	override bool WantsSectors() { return RSS.GetB("rss_fx_glow", false); }
	override bool WantsActors() { return false; }
	// Sector glow is render state, and its claim markers are client-side.
	override bool LookOnly() { return true; }

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_glow", false)) return;

		double wall = RSS.GetF("rss_fx_glow_wall", 96.0);
		double flat = RSS.GetF("rss_fx_glow_flat", 140.0);

		// THE FLATS BELONG TO RECOLOUR WHILE RECOLOUR IS ON. Both effects write
		// the same flat lanes and both claim PART_FLATS, and the claim table
		// keeps ONE owner per part -- so this one, registered later, took the
		// flats outright. Two things followed: the Recolour reach row was live
		// and inert, because the reach came from here instead; and switching
		// this effect off released flats Recolour was still painting, which
		// handed those rooms to GlowInTheDark while Recolour believed it held
		// them.
		//
		// Yielding rather than arbitrating, because the two write the same
		// colour to the same lanes at the same default reach -- at the defaults
		// this changes nothing on screen, and it gives the flats one owner.
		// The walls are untouched and stay this effect's.
		if (RSS.GetB("rss_fx_recolour", false)) flat = 0.0;

		int parts = 0;

		if (wall > 0.0)
		{
			s.SetGlowColor(Sector.floor, tint);
			s.SetGlowColor(Sector.ceiling, tint);
			s.SetGlowColorFar(Sector.floor, tint);
			s.SetGlowColorFar(Sector.ceiling, tint);
			s.SetGlowHeight(Sector.floor, wall);
			s.SetGlowHeight(Sector.ceiling, wall * 0.75);
			parts |= RSS_SectorClaim.PART_WALLS;
		}
		if (flat > 0.0)
		{
			s.SetFlatGlowColor(Sector.floor, tint);
			s.SetFlatGlowColor(Sector.ceiling, tint);
			s.SetFlatGlowColorFar(Sector.floor, tint);
			s.SetFlatGlowColorFar(Sector.ceiling, tint);
			s.SetFlatGlowHeight(Sector.floor, flat);
			s.SetFlatGlowHeight(Sector.ceiling, flat * 0.7);
			parts |= RSS_SectorClaim.PART_FLATS;
		}

		if (parts != 0) RSS_Handler.ClaimSector(s, parts, RSS_SectorClaim.BY_GLOW);
	}

	// Switched off -- this effect, the Effects page, or the whole mod -- and every
	// part it painted is handed back. The colour itself stays until something
	// else paints there: with GITD loaded that is GITD's next look at the map,
	// and with it absent nothing does, the same as a sweep has always left it.
	override void OnTicDone()
	{
		if (RSS.GetB("rss_enabled", true) && RSS.GetB("rss_fx", false)
			&& RSS.GetB("rss_fx_glow", false)) return;
		RSS_Handler.ReleaseClaims(RSS_SectorClaim.BY_GLOW);
	}
}

// ---------------------------------------------------------------------------
// A SWEEP'S CLAIM ON A SECTOR'S GLOW.
//
// A swept room keeps the sweep's colour -- that is the whole point of the glow
// effects. But sector glow is shared engine state, and anything else that
// paints it paints over a sweep. GlowInTheDark repaints every sector when one
// of its settings moves, and again when a light or a flat changes under it;
// and switching it off cleared every sector, the sweep's included.
//
// So the glow effects leave a CLAIM on what they painted, and a mod that paints
// sector glow can pass claimed parts by. Neither mod names the other. The
// contract is this class NAME, looked up from a string at run time, and base
// Actor fields only:
//
//   where    a CLIENT-SIDE actor in Thinker.STAT_INFO --
//            ThinkerIterator.Create(name, Thinker.STAT_INFO, true)
//   args[0]  the sector's index in Level.Sectors
//   args[1]  the parts claimed: PART_WALLS (both wall glows), PART_FLATS (both
//            flat glows), or both. One marker per claimed sector.
//
// A claim lasts for the map. It is let go when the effect that painted it is
// switched off (the OnTicDone of RSS_FxGlow and RSS_FxRecolour), and it goes
// with the map. Nothing else takes it away.
//
// CLIENT-SIDE, BECAUSE WHAT IT DESCRIBES IS. Sector glow is render state, and
// the crossings that paint it are not the same on every machine: a "follows
// you" sweep leaves from each player's own camera, and "when YOU are hurt"
// fires on one machine only. A playsim actor spawned from there would make a
// different number of actors on each peer, and every playsim actor takes the
// next free network id (NetworkEntityManager::AddNetworkEntity) -- so the ids
// of everything spawned after it would disagree between machines. A client-side
// actor takes no id and lives in its own collection.
//
// STAT_INFO, so it never thinks and nothing walking the level's actors ever
// meets it: that list sits below STAT_FIRST_THINKING, which is where both the
// ticker and a default ThinkerIterator start.
//
// NOT SAVED. Client-side thinkers are not written into a savegame. The handler
// keeps who painted what in a saved table and puts the markers back after a
// load -- see RSS_Handler.PublishClaims. The glow itself the engine does save.
class RSS_SectorClaim : Actor
{
	const PART_WALLS = 1;
	const PART_FLATS = 2;

	// Which effect painted a part, so switching one effect off lets go of only
	// what that effect painted. One bit each, 1 2 4 or 8: the handler keeps
	// them as a mask and packs one per part into four bits.
	const BY_GLOW     = 1;
	const BY_RECOLOUR = 2;

	Default
	{
		+NOINTERACTION
		+NOBLOCKMAP
		+NOSECTOR
		+NOGRAVITY
		+DONTSPLASH
		+NOTONAUTOMAP
		RenderStyle "None";
	}

	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}
}

// LIGHT. Move the sector's own light level as the front passes -- a wave that
// puts a room out, or brings one up. Signed, so one preset does both.
//
// GAMEPLAY, not look. The light level is playsim state: light thinkers step
// from it, and scripts read it for sight and stealth. So in a netgame only a
// shared band moves it -- see RSS_Effect.LookOnly.
class RSS_FxLight : RSS_Effect
{
	override bool WantsSectors() { return RSS.GetB("rss_fx_light", false); }
	override bool WantsActors() { return false; }

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_light", false)) return;
		int step = RSS.GetI("rss_fx_light_step", -32);
		if (step == 0) return;
		int floorL = RSS.GetI("rss_fx_light_floor", 0);
		int ceilL  = RSS.GetI("rss_fx_light_ceil", 255);

		// NEVER READ `lightlevel` AND WRITE IT BACK THROUGH SetLightLevel WHEN A
		// TRIM MAY BE IN PLAY. `lightlevel` is the TRIMMED value; SetLightLevel
		// writes LightTrimBase. Read-modify-write across those two folds the
		// trim into the base permanently and the original is gone -- so on a
		// room RS_Ballistics has dimmed for shot-out lights (base 160, dim 0.6,
		// effective 64) a -32 step wrote base 32, the room lost 51 rather than
		// 32, and repairing the lamp restored it to 32 instead of 160. Take the
		// base, do the arithmetic there, write that back.
		//
		// GetLightTrimBase() falls back to lightlevel when nothing is trimmed,
		// so with RS_Ballistics absent this is byte-identical to what it was.
		s.SetLightLevel(clamp(s.GetLightTrimBase() + step, floorL, ceilL));
	}
}

// FOG, COLOURED. Mix the sweep's colour through the mist, so a blue sweep
// leaves blue fog behind it. The gradient lane is used rather than the slab's
// own colour because that leaves the slab's shape, height and density exactly
// as the player set them -- this recolours, it does not take the fog over.
//
// THROUGH RS_FOG, NOT THE ENGINE. RS_Fog pushes its gradient every tic from
// WorldTick and UiTick, so a direct SetFogGradient from here was put back
// before a frame was ever drawn. RS_Fog reads rsf_tint_r/g/b and rsf_tint_mix
// -- nosave, local, immediate -- and pushes those in place of its own gradient
// while the mix is above 0. Written once per band per tic, and the mix goes
// back to 0 when the last band ends.
class RSS_FxFogTint : RSS_Effect
{
	private bool wroteThisBand;
	private bool held;

	override bool WantsSectors()
	{
		return RSS.GetB("rss_fx_fogtint", false) && CVar.FindCVar("rsf_tint_mix") != null;
	}
	override bool WantsActors() { return false; }
	// RS_Fog draws with the nosave tint cvars and nothing else reads them.
	override bool LookOnly() { return true; }

	override void OnFrontMoved(Vector3 origin, double front, Color tint)
	{
		wroteThisBand = false;
	}

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (wroteThisBand || !RSS.GetB("rss_fx_fogtint", false)) return;
		let mixCv = CVar.FindCVar("rsf_tint_mix");
		if (!mixCv) return;

		wroteThisBand = true;
		RSS.SetI("rsf_tint_r", tint.r);
		RSS.SetI("rsf_tint_g", tint.g);
		RSS.SetI("rsf_tint_b", tint.b);
		mixCv.SetFloat(clamp(RSS.GetF("rss_fx_fogtint_mix", 0.7), 0.0, 1.0));
		held = true;
	}

	override void OnBandEnd(Vector3 origin)
	{
		if (held && !RSS_Handler.AnyBandLive()) Release();
	}

	override void OnTicDone()
	{
		if (held && !(RSS.GetB("rss_fx", false) && RSS.GetB("rss_fx_fogtint", false)))
			Release();
	}

	override void ResetForMap()
	{
		if (held) Release();
	}

	private void Release()
	{
		RSS.SetF("rsf_tint_mix", 0.0);
		held = false;
	}
}

// DARKNESS. Drive how dark the level is as the wave travels -- a front that
// puts the lights out behind it, or brings them back.
//
// THROUGH AN OFFSET RS_DARKNESS ADDS, never the player's own Amount. RS_Darkness
// pushes the whole darkness state every tic from its cvars, so writing the
// engine value directly would be overwritten within a tic. Writing rsd_adjust
// instead was worse: it is a SERVER cvar, so every sector in a tic read the
// same stale value and queued its own network write, the steps did not add
// up, and the player's saved Darkness setting was changed for good with
// nothing to put it back.
//
// So this keeps its OWN running offset, and publishes it at most once a tic
// through rsd_sweep_offset -- nosave, which RS_Darkness adds on top of
// rsd_adjust. Looked up at run time: an RS_Darkness without it, or none at
// all, and this does nothing. Back to 0 when the last band ends and at every
// map change.
class RSS_FxDarken : RSS_Effect
{
	private double runningOffset;   // this mod's own total, in rsd_adjust units
	private double published;       // what rsd_sweep_offset was last set to
	private bool dirty;

	override bool WantsSectors() { return RSS.GetB("rss_fx_dark", false) && RSS.HasDarkness(); }
	override bool WantsActors() { return false; }
	// RS_Darkness draws with rsd_sweep_offset; no sector light is touched.
	override bool LookOnly() { return true; }

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_dark", false)) return;
		double step = RSS.GetF("rss_fx_dark_step", 8.0);
		if (step == 0.0) return;
		runningOffset += step;
		dirty = true;
	}

	override void OnBandEnd(Vector3 origin)
	{
		if (RSS_Handler.AnyBandLive()) return;
		runningOffset = 0.0;
		dirty = true;
	}

	override void OnTicDone()
	{
		// Switched off mid-band: nothing of this mod's stays in the level.
		if (!RSS.GetB("rss_fx", false) || !RSS.GetB("rss_fx_dark", false))
		{
			runningOffset = 0.0;
			dirty = (published != 0.0);
		}
		if (!dirty) return;
		dirty = false;

		let offsetCv = CVar.FindCVar("rsd_sweep_offset");
		if (!offsetCv)
		{
			runningOffset = 0.0;
			published = 0.0;
			return;
		}

		// THE LIMITS ARE ON WHERE THE DARKNESS ENDS UP, not on the offset, so
		// "never below" and "never above" mean what the menu says. Widened to
		// take in the player's own Amount, so a limit set on the wrong side of
		// it only stops the sweep going further and never drags the darkness
		// the other way. The total is kept clamped, so it cannot run away past
		// a limit and take as long again to come back.
		double adjust = RSS.GetF("rsd_adjust", 128.0);
		double lo = min(RSS.GetF("rss_fx_dark_min", 0.0), adjust);
		double hi = max(RSS.GetF("rss_fx_dark_max", 224.0), adjust);
		runningOffset = clamp(adjust + runningOffset, lo, hi) - adjust;
		if (runningOffset == published) return;
		offsetCv.SetFloat(runningOffset);
		published = runningOffset;
	}

	override void ResetForMap()
	{
		runningOffset = 0.0;
		dirty = false;
		if (published == 0.0) return;
		let offsetCv = CVar.FindCVar("rsd_sweep_offset");
		if (offsetCv) offsetCv.SetFloat(0.0);
		published = 0.0;
	}
}

// COLOUR DRAIN. Take the colour out of the world as the front passes, or put it
// back. One number, scene-wide, and the cheapest dramatic thing in here.
//
// It is ONE value however many bands are out, so "put it back after" waits for
// the LAST of them -- the first to end used to snap the world back to full
// colour while a second was still draining it. And it is engine state that no
// map change resets, so it is put back then too, whatever the switch says: a
// map ending mid-drain used to open the next one grey.
class RSS_FxDesat : RSS_Effect
{
	private double desatAcc;
	private bool held;

	override bool WantsSectors() { return RSS.GetB("rss_fx_desat", false); }
	override bool WantsActors() { return false; }
	// The global drain is a shader uniform.
	override bool LookOnly() { return true; }

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_desat", false)) return;
		double step = RSS.GetF("rss_fx_desat_step", 0.05);
		if (step == 0.0) return;
		desatAcc = clamp(desatAcc + step, 0.0, 1.0);
		Level.SetDesatGlobal(desatAcc);
		held = true;
	}

	override void OnBandEnd(Vector3 origin)
	{
		if (!held || !RSS.GetB("rss_fx_desat_reset", true)) return;
		if (RSS_Handler.AnyBandLive()) return;
		Release();
	}

	override void OnTicDone()
	{
		if (held && !(RSS.GetB("rss_fx", false) && RSS.GetB("rss_fx_desat", false)))
			Release();
	}

	override void ResetForMap()
	{
		if (held) Release();
	}

	private void Release()
	{
		desatAcc = 0.0;
		Level.SetDesatGlobal(0.0);
		held = false;
	}
}

// DECORATIONS. Outline whatever the front reaches in the sweep's colour, using
// the per-actor outline the engine already carries -- so a wave passing a room
// traces the lamps, barrels, corpses and gore in its own colour.
//
// Mode 1 keeps the body and adds the edge, which is the only one of the three
// that suits a decoration: wire and ghost erase or flatten the sprite, and a
// barrel that stops being a barrel is a worse effect than no effect.
//
// THE OUTLINE STAYS. It is saved with the actor and nothing takes it off, the
// same as the glow and light a sweep leaves behind -- the place is changed
// behind the wave, which is the point.
class RSS_FxDecor : RSS_Effect
{
	override bool WantsSectors() { return false; }
	override bool WantsActors() { return RSS.GetB("rss_fx_decor", false); }
	// The outline fields are read by the sprite renderer and written to saves;
	// nothing in the playsim reads them.
	override bool LookOnly() { return true; }

	override void OnActor(Actor a, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_decor", false)) return;
		if (!a || a.player) return;
		if (a.health <= 0 && !a.bCorpse) return;

		// A monster CORPSE is decoration, whatever "Monsters too" says. Death
		// leaves the monster flag on, so the corpses the menu promised were all
		// being skipped.
		if (a.bIsMonster && a.health > 0 && !RSS.GetB("rss_fx_decor_monsters", false))
			return;

		a.OutlineColorA = tint;
		a.OutlineColorB = tint;
		a.OutlineStrength = RSS.GetF("rss_fx_decor_strength", 0.8);
		a.OutlineThickness = RSS.GetF("rss_fx_decor_thickness", 1.2);
		a.OutlineThreshold = RSS.GetF("rss_fx_decor_threshold", 0.2);
		a.OutlineGlow = RSS.GetF("rss_fx_decor_glow", 2.5);
		a.OutlinePulse = 0.0;
		a.OutlineMode = 1;
	}
}

// ---------------------------------------------------------------------------
// WHERE THE EFFECT LIST LIVES.
//
// ZScript has no static data members, so a plain `static Array` on the handler
// is not a thing that compiles. A StaticEventHandler is the idiom for state
// that has to outlive any one level -- a mod registers an effect once, at
// startup, and expects it to still be there three maps later.
// ---------------------------------------------------------------------------

class RSS_Registry : StaticEventHandler
{
	Array<RSS_Effect> effects;

	static RSS_Registry Get()
	{
		return RSS_Registry(StaticEventHandler.Find("RSS_Registry"));
	}

	void Add(RSS_Effect fx)
	{
		// No id, no entry -- see RSS_Handler.Register.
		if (!fx || fx.id.Length() == 0) return;
		// Replace a same-id registration rather than stacking a second copy,
		// which is what would otherwise happen on every map load.
		for (int i = 0; i < effects.Size(); i++)
			if (effects[i] && effects[i].id == fx.id) { effects[i] = fx; return; }
		effects.Push(fx);
	}
}
