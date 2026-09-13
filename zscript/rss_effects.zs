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
	const RIPPLES_PER_BAND = 3;
	private int rippled;

	override bool WantsSectors() { return RSS.GetB("rss_fx_fog", false) && RSS.HasFog(); }
	override bool WantsActors() { return false; }

	override void OnFrontMoved(Vector3 origin, double front, Color tint)
	{
		rippled = 0;
	}

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_fog", false)) return;
		if (rippled >= RIPPLES_PER_BAND) return;
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
// worked with GITD loaded would be a worse thing to have built.
class RSS_FxRecolour : RSS_Effect
{
	override bool WantsSectors() { return RSS.GetB("rss_fx_recolour", false); }
	override bool WantsActors() { return false; }

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
	}
}

// Wake what the front reaches. A sweep that alerts the level is a gameplay
// event rather than a decoration, and it is the smallest honest example of the
// frontier changing the game rather than the picture.
class RSS_FxRouse : RSS_Effect
{
	override bool WantsSectors() { return false; }
	override bool WantsActors() { return RSS.GetB("rss_fx_rouse", false); }

	override void OnActor(Actor a, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_rouse", false)) return;
		if (!a || !a.bIsMonster || a.health <= 0) return;
		if (a.target != null) return;

		let pmo = players[consoleplayer].mo;
		if (pmo) a.target = pmo;
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
// colour. (GITD still repaints the whole map on its own settings change and
// will take the sweep's colours with it; skipping swept sectors is GITD's to
// add.)
class RSS_FxGlow : RSS_Effect
{
	override bool WantsSectors() { return RSS.GetB("rss_fx_glow", false); }
	override bool WantsActors() { return false; }

	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_glow", false)) return;

		double wall = RSS.GetF("rss_fx_glow_wall", 96.0);
		double flat = RSS.GetF("rss_fx_glow_flat", 140.0);

		if (wall > 0.0)
		{
			s.SetGlowColor(Sector.floor, tint);
			s.SetGlowColor(Sector.ceiling, tint);
			s.SetGlowColorFar(Sector.floor, tint);
			s.SetGlowColorFar(Sector.ceiling, tint);
			s.SetGlowHeight(Sector.floor, wall);
			s.SetGlowHeight(Sector.ceiling, wall * 0.75);
		}
		if (flat > 0.0)
		{
			s.SetFlatGlowColor(Sector.floor, tint);
			s.SetFlatGlowColor(Sector.ceiling, tint);
			s.SetFlatGlowColorFar(Sector.floor, tint);
			s.SetFlatGlowColorFar(Sector.ceiling, tint);
			s.SetFlatGlowHeight(Sector.floor, flat);
			s.SetFlatGlowHeight(Sector.ceiling, flat * 0.7);
		}
	}
}

// LIGHT. Move the sector's own light level as the front passes -- a wave that
// puts a room out, or brings one up. Signed, so one preset does both.
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
		s.SetLightLevel(clamp(s.lightlevel + step, floorL, ceilL));
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
