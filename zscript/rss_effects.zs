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
// at all. An effect is an object with two methods; the handler walks whatever
// is registered and knows nothing about any of them.
//
// Register from any mod:
//
//   class MyEffect : RSS_Effect
//   {
//       override void OnActor(Actor a, Vector3 origin, double front, Color tint) { ... }
//   }
//   RSS_Handler.Register(new("MyEffect"));
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
	// recycled. Somewhere to put "and now put it all back".
	virtual void OnBandEnd(Vector3 origin) {}
}

// ---------------------------------------------------------------------------
// The built-ins. Each is a proof that the frontier works and a useful effect in
// its own right; none of them is the interesting one, which is monster tiering
// and is deliberately not guessed at here.
// ---------------------------------------------------------------------------

// A ripple pushed into the fog as the front passes, so mist reacts to a sweep
// instead of ignoring it. Costs nothing when RS_Fog is not loaded: the engine
// keeps the disturbance array either way and the shader reads it only when a
// slab exists.
class RSS_FxFogRipple : RSS_Effect
{
	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_fog", false)) return;
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
		s.SetFlatGlowHeight(Sector.floor, reach);
		s.SetFlatGlowHeight(Sector.ceiling, reach * 0.7);
	}

	// Kept: a hue helper, for a caller that wants to derive a colour rather
	// than take the band's.
	static Color HueColor(double h, double sat, double val)
	{
		h = (h - floor(h)) * 6.0;
		int i = int(h);
		double f = h - i;
		double p = val * (1.0 - sat);
		double q = val * (1.0 - sat * f);
		double t = val * (1.0 - sat * (1.0 - f));
		double r, g, b;
		if      (i == 0) { r = val; g = t;   b = p;   }
		else if (i == 1) { r = q;   g = val; b = p;   }
		else if (i == 2) { r = p;   g = val; b = t;   }
		else if (i == 3) { r = p;   g = q;   b = val; }
		else if (i == 4) { r = t;   g = p;   b = val; }
		else             { r = val; g = p;   b = q;   }
		return Color(255, int(r * 255), int(g * 255), int(b * 255));
	}
}

// Wake what the front reaches. A sweep that alerts the level is a gameplay
// event rather than a decoration, and it is the smallest honest example of the
// frontier changing the game rather than the picture.
class RSS_FxRouse : RSS_Effect
{
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
	override void OnActor(Actor a, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_crossed", true)) return;
		if (!a) return;

		// Skipped outright when nothing that overrides the hook is loaded, so a
		// sweep with no monster mod present does not walk every actor in the
		// level to call an empty function on each of them.
		if (!RSS.HasMonsterTiers() && !RSS.GetB("rss_fx_crossed_always", false)) return;

		a.OnSweepCrossed(origin, front, tint);
	}
}

// GLOW. Repaint the sector the front crosses in the sweep's colour -- both the
// wall glow it throws and its own flat-edge glow. This is the one that makes a
// sweep read as having CHANGED the room rather than lit it for a moment.
class RSS_FxGlow : RSS_Effect
{
	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_glow", false)) return;

		double wall = RSS.GetF("rss_fx_glow_wall", 96.0);
		double flat = RSS.GetF("rss_fx_glow_flat", 140.0);

		if (wall > 0.0)
		{
			s.SetGlowColor(Sector.floor, tint);
			s.SetGlowColor(Sector.ceiling, tint);
			s.SetGlowHeight(Sector.floor, wall);
			s.SetGlowHeight(Sector.ceiling, wall * 0.75);
		}
		if (flat > 0.0)
		{
			s.SetFlatGlowColor(Sector.floor, tint);
			s.SetFlatGlowColor(Sector.ceiling, tint);
			s.SetFlatGlowHeight(Sector.floor, flat);
			s.SetFlatGlowHeight(Sector.ceiling, flat * 0.7);
		}
	}
}

// LIGHT. Move the sector's own light level as the front passes -- a wave that
// puts a room out, or brings one up. Signed, so one preset does both.
class RSS_FxLight : RSS_Effect
{
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
class RSS_FxFogTint : RSS_Effect
{
	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_fogtint", false)) return;
		if (!RSS.HasFog()) return;
		Level.SetFogGradient(tint, clamp(RSS.GetF("rss_fx_fogtint_mix", 0.7), 0.0, 1.0));
	}
}

// DARKNESS. Drive how dark the level is as the wave travels -- a front that
// puts the lights out behind it, or brings them back.
//
// Written through RS_Darkness's own cvar rather than by calling SetDarkness
// directly, and that is deliberate: RS_Darkness pushes the whole darkness state
// every tic from that cvar, so writing the engine value directly would be
// overwritten within a tic. Moving the cvar makes the change stick and keeps
// the Darkness menu telling the truth about what is set.
class RSS_FxDarken : RSS_Effect
{
	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_dark", false)) return;
		if (!RSS.HasDarkness()) return;

		double step = RSS.GetF("rss_fx_dark_step", 8.0);
		if (step == 0.0) return;
		double lo = RSS.GetF("rss_fx_dark_min", 0.0);
		double hi = RSS.GetF("rss_fx_dark_max", 224.0);
		double now = RSS.GetF("rsd_adjust", 128.0);
		RSS.SetF("rsd_adjust", clamp(now + step, lo, hi));
	}
}

// COLOUR DRAIN. Take the colour out of the world as the front passes, or put it
// back. One number, scene-wide, and the cheapest dramatic thing in here.
class RSS_FxDesat : RSS_Effect
{
	override void OnSector(Sector s, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_desat", false)) return;
		double step = RSS.GetF("rss_fx_desat_step", 0.05);
		if (step == 0.0) return;
		desatAcc = clamp(desatAcc + step, 0.0, 1.0);
		Level.SetDesatGlobal(desatAcc);
	}

	override void OnBandEnd(Vector3 origin)
	{
		if (RSS.GetB("rss_fx_desat_reset", true)) { desatAcc = 0.0; Level.SetDesatGlobal(0.0); }
	}

	private double desatAcc;
}

// DECORATIONS. Outline whatever the front reaches in the sweep's colour, using
// the per-actor outline the engine already carries -- so a wave passing a room
// traces the lamps, barrels, corpses and gore in its own colour.
//
// Mode 1 keeps the body and adds the edge, which is the only one of the three
// that suits a decoration: wire and ghost erase or flatten the sprite, and a
// barrel that stops being a barrel is a worse effect than no effect.
class RSS_FxDecor : RSS_Effect
{
	override void OnActor(Actor a, Vector3 origin, double front, Color tint)
	{
		if (!RSS.GetB("rss_fx_decor", false)) return;
		if (!a || a.health <= 0 && !a.bCorpse) return;

		bool monsters = RSS.GetB("rss_fx_decor_monsters", false);
		if (a.bIsMonster && !monsters) return;
		if (a.player) return;

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
		if (!fx) return;
		// Replace a same-id registration rather than stacking a second copy,
		// which is what would otherwise happen on every map load.
		for (int i = 0; i < effects.Size(); i++)
			if (effects[i] && effects[i].id == fx.id) { effects[i] = fx; return; }
		effects.Push(fx);
	}
}
