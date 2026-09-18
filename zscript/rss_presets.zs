// RS_Sweeps -- presets.
//
// A preset is a batch of CVar writes and nothing else, as everywhere else in
// this family. It owns WHAT a band looks like and how it moves. It does NOT
// touch rss_enabled, and it does not touch the trigger switches on the Sources
// page -- those are what the player turns on and off, and a preset stamping
// over them reads as the mod switching itself on.

class RSS_Presets
{
	// How many Apply knows about. Kept beside them so adding one and
	// forgetting this is a compile-visible mistake rather than a silent one.
	const COUNT = 35;

	static void F(String n, double v) { let c = CVar.FindCVar(n); if (c) c.SetFloat(v); }
	static void I(String n, int v)    { let c = CVar.FindCVar(n); if (c) c.SetInt(v); }
	// Bools through SetBool, as GlowInTheDark's presets write them. Not called
	// B: identifiers are case-insensitive and RGB below has a parameter named b.
	static void Flag(String n, bool v) { let c = CVar.FindCVar(n); if (c) c.SetBool(v); }

	// The train: one clock in map units a second, and tics between bands.
	static void Train(double speed, int gap)
	{
		F("rss_train_speed", speed); I("rss_train_gap", gap);
	}

	// One row of the per-band table. Colour is packed 0xRRGGBB; thickness and
	// draw 0 mean "the shared value".
	static void BandSlot(int n, int rgb, int thick, int draw)
	{
		I("rss_band_col" .. n, rgb);
		I("rss_band_thick" .. n, thick);
		I("rss_band_draw" .. n, draw);
	}

	static void RGB(String pre, int r, int g, int b)
	{
		I(pre .. "_r", r); I(pre .. "_g", g); I(pre .. "_b", b);
	}

	// The band itself.
	//
	// THE WAKE IS IN MAP UNITS, and the shader only stretches a band once it is
	// LONGER than the thickness (SweepBandAttenAt in main.fp) -- shorter and the
	// band stays symmetric. So every wake below is written against its own
	// band's thickness, and 0 where the look wants none.
	static void Band(double thickness, double softness, double intensity,
		double trail, int draw, double fade)
	{
		F("rss_thickness", thickness); F("rss_softness", softness);
		F("rss_intensity", intensity); F("rss_trail", trail);
		I("rss_draw", draw);           F("rss_fade", fade);
	}

	// How the standing bands travel.
	static void Ambient(int count, double speed, double reach, int shape)
	{
		I("rss_ambient_count", count); F("rss_ambient_speed", speed);
		F("rss_ambient_reach", reach); I("rss_ambient_shape", shape);
	}

	// What a fired band does. SPEED IS TIME: the band always travels exactly
	// `reach`, over `life` / `speed` seconds. The presets with a speed other
	// than 1 were retuned when that changed, so each still covers the distance
	// in the time it always did.
	static void Event(double life, double reach, double speed, int shape)
	{
		F("rss_ev_life", life);   F("rss_ev_reach", reach);
		F("rss_ev_speed", speed); I("rss_ev_shape", shape);
	}

	// The lattice. Mode 0 turns it off and the band is a plain wash.
	static void Fill(int mode, double u, double v, double width, double soft,
		double gap, double air)
	{
		I("rss_fill", mode);      F("rss_fill_u", u);
		F("rss_fill_v", v);       F("rss_fill_width", width);
		F("rss_fill_soft", soft); F("rss_fill_gap", gap);
		F("rss_fill_air", air);
	}

	static void FillMotion(double rotate, double drift, double major,
		double boost, double jitter, double flicker, double grad, int gradAxis)
	{
		F("rss_fill_rotate", rotate); F("rss_fill_drift", drift);
		F("rss_fill_major", major);   F("rss_fill_boost", boost);
		F("rss_fill_jitter", jitter); F("rss_fill_flicker", flicker);
		F("rss_fill_grad", grad);     I("rss_fill_grad_axis", gradAxis);
	}

	// EVERY TERM, NEUTRAL, before a preset runs -- so a preset states only what
	// it cares about and can never wear the leftovers of the one before it.
	// RS_Fog shipped without this and seven of its presets inherited a split
	// they never asked for. Cheaper to start with it than to add it after.
	static void Base()
	{
		Band(26.0, 0.55, 1.30, 0.0, 1, 0.35);
		Ambient(2, 0.35, 900.0, 1);
		Event(1.1, 700.0, 1.0, 1);
		Fill(0, 48.0, 48.0, 3.0, 1.5, 0.35, 0.0);
		FillMotion(0, 0, 0, 2.0, 0, 0, 0, 0);
		RGB("rss_col", 120, 200, 255);
		RGB("rss_col2", 255, 90, 160);
		RGB("rss_fill", 255, 255, 255);
		F("rss_col_mix", 0.0);
		I("rss_ambient_org", 1);
		I("rss_ambient_timing", 0);
		Train(128.0, 140);
		Flag("rss_perband", false);
	}

	// ---- WALLS YOU CANNOT SEE THROUGH ---------------------------------------
	//
	// A band wide enough, solid enough and drawn IN THE AIR stops being a line
	// of light and becomes a moving wall. You do not see what is behind it
	// until it has gone past you.
	//
	// Four of them, and the difference between the first two is one setting:
	//
	//   ADD   -- the wall blows out to white. Blinding, and you cannot see
	//            through it because everything is saturated.
	//   CRUSH -- the wall blends the view toward its own colour instead of
	//            adding to it. Black is pitch darkness you cannot see into.
	//
	// Both need fill mode 3 (solid slab) and air at 1, or the lattice is a
	// pattern with gaps and the gaps are exactly what you see through.

	// A wall of light. Blinding rather than dark -- you lose the room to white.
	static void WallOfLight()
	{
		Band(150.0, 1.6, 2.6, 0.0, 1, 0.25);
		Ambient(1, 0.14, 1600.0, 2);
		Event(2.0, 1400.0, 1.0, 2);
		RGB("rss_col", 255, 250, 230);
		RGB("rss_fill", 255, 255, 255);
		Fill(3, 1.0, 1.0, 1.0, 0.2, 1.0, 1.0);
		FillMotion(0, 0, 0, 2.0, 0, 0.04, 0, 0);
	}

	// A wall of pitch darkness. Crush occludes rather than adds, so the view
	// is blended to black inside the band and there is nothing to see.
	static void WallOfDark()
	{
		Band(150.0, 1.6, 1.0, 0.0, 3, 0.2);
		Ambient(1, 0.12, 1600.0, 2);
		Event(2.2, 1400.0, 1.0, 2);
		RGB("rss_col", 10, 10, 14);
		RGB("rss_fill", 0, 0, 0);
		Fill(3, 1.0, 1.0, 1.0, 0.2, 1.0, 1.0);
		FillMotion(0, 0, 0, 2.0, 0, 0, 0, 0);
	}

	// A wall of solid colour. Same occlusion as the dark one, but the view is
	// blended to a colour instead of to black -- you are inside it, not blind.
	static void WallOfColour()
	{
		Band(140.0, 1.5, 1.0, 0.0, 3, 0.25);
		Ambient(1, 0.14, 1500.0, 1);
		Event(2.0, 1300.0, 1.0, 1);
		RGB("rss_col", 40, 90, 190);
		RGB("rss_fill", 30, 80, 200);
		Fill(3, 1.0, 1.0, 1.0, 0.2, 1.0, 0.92);
		FillMotion(0, 4.0, 0, 2.0, 0.05, 0.06, 0.0, 0);
	}

	// A rolling bank of fog rather than a hard wall -- softer edges, a churning
	// lattice instead of a slab, and it only PARTLY occludes, so shapes loom
	// out of it before they arrive.
	static void WallOfFog()
	{
		Band(220.0, 2.2, 1.0, 264.0, 3, 0.35);
		Ambient(1, 0.10, 1800.0, 2);
		Event(2.34, 1350.0, 0.9, 2);
		RGB("rss_col", 150, 155, 165);
		RGB("rss_fill", 140, 146, 158);
		Fill(3, 1.0, 1.0, 1.0, 0.2, 1.0, 0.62);
		FillMotion(6.0, 9.0, 0, 2.0, 0.35, 0.18, 0.4, 1);
	}

	// ---- ACTUAL SWEEPS ------------------------------------------------------
	//
	// One front, starting off one edge of the map and travelling to the other.
	// Shapes 6 to 9 are SIGNED, which is the whole difference: 2 and 3 are
	// abs(), so they are two planes moving apart from the middle -- a split,
	// not a sweep.
	//
	// A signed shape ignores the reach setting: the handler gives it the map's
	// own span, because a sweep that stops halfway is not one. The origin
	// setting still picks WHICH crossing -- "follows you" starts the front at
	// your feet, anything else puts it off the near edge. Base() leaves it
	// following you, so every preset here sets the map centre (3) for the edge
	// crossing these are written as.
	//
	// Switch the timing to Once and any of these is a single slow pass, sent at
	// map start and by the "Send a sweep" key, with the place changed behind it.

	// The plain one. A single front crossing the level west to east, slowly
	// enough that you watch it come.
	static void Sweep()
	{
		Band(70.0, 1.0, 1.1, 96.0, 1, 0.15);
		Ambient(1, 0.10, 4096.0, 6);
		I("rss_ambient_org", 3);
		RGB("rss_col", 120, 200, 255);
		RGB("rss_col2", 255, 140, 60);
		F("rss_col_mix", 0.8);
	}

	// The same, coming back the other way, and north to south rather than east
	// to west so two of these running together cross.
	static void Sweepback()
	{
		Band(70.0, 1.0, 1.1, 96.0, 1, 0.15);
		Ambient(1, 0.10, 4096.0, 9);
		I("rss_ambient_org", 3);
		RGB("rss_col", 255, 140, 60);
		RGB("rss_col2", 120, 200, 255);
		F("rss_col_mix", 0.8);
	}

	// A front that takes the light with it. Crush, so the level goes dark
	// behind it rather than lighting up -- pair it with the darkness or the
	// retier effect and it is a wave that changes the map as it passes. The
	// 220 wake is twice the band, so the dark drags out behind the front.
	static void Purge()
	{
		Band(110.0, 1.4, 1.2, 220.0, 3, 0.1);
		Ambient(1, 0.07, 4096.0, 6);
		I("rss_ambient_org", 3);
		RGB("rss_col", 20, 14, 26);
		RGB("rss_fill", 8, 6, 12);
		Fill(3, 1.0, 1.0, 1.0, 0.2, 1.0, 0.75);
	}

	// A wall crossing the map that you genuinely cannot see through, so
	// whatever is on the far side arrives without warning.
	static void Curtain()
	{
		Band(200.0, 1.8, 1.0, 0.0, 3, 0.08);
		Ambient(1, 0.06, 4096.0, 7);
		I("rss_ambient_org", 3);
		RGB("rss_col", 15, 15, 20);
		RGB("rss_fill", 0, 0, 0);
		Fill(3, 1.0, 1.0, 1.0, 0.2, 1.0, 1.0);
	}

	static void Apply(int idx)
	{
		Base();

		switch (idx)
		{
		default:
		case 0:  Off();          break;
		case 1:  Tide();         break;
		case 2:  Patrol();       break;
		case 3:  Sonar();        break;
		case 4:  Shockwave();    break;
		case 5:  Corridor();     break;
		case 6:  Rising();       break;
		case 7:  Dragnet();      break;
		case 8:  Cage();         break;
		case 9:  Hologram();     break;
		case 10: Interference(); break;
		case 11: Bloodrush();    break;
		case 12: Carnival();     break;
		case 13: WallOfLight();  break;
		case 14: WallOfDark();   break;
		case 15: WallOfColour(); break;
		case 16: WallOfFog();    break;
		case 17: Sweep();        break;
		case 18: Sweepback();    break;
		case 19: Purge();        break;
		case 20: Curtain();      break;
		case 21: Unison();       break;
		// -- the same looks, crossing the map --
		case 22: TideCross();         break;
		case 23: PatrolCross();       break;
		case 24: CorridorCross();     break;
		case 25: DragnetCross();      break;
		case 26: CageCross();         break;
		case 27: HologramCross();     break;
		case 28: InterferenceCross(); break;
		case 29: BloodrushCross();    break;
		case 30: CarnivalCross();     break;
		case 31: WallOfLightCross();  break;
		case 32: WallOfDarkCross();   break;
		case 33: WallOfColourCross(); break;
		case 34: WallOfFogCross();    break;
		}
	}

	// ---- UNISON -------------------------------------------------------------
	//
	// GlowInTheDark's Neon Unison band, carried over number for number from
	// PresetProfile.zs in the Radiance Control Panel pk3. ONLY THE BAND. The
	// cool lanes it crosses, the fog, the darkness and the bloom belong to
	// RS_GlowInTheDark, RS_Fog, RS_Darkness and the engine, and a sweep preset
	// reaching into those would be this mod switching other mods on.
	//
	// Eight rings leaving the map centre on one clock: 128 units a second, 140
	// tics apart, so 512 units between bands. The downbeat is 260 wide and the
	// rest are 110-unit ticks. The fifth is a hole -- a crush band, 150 wide, so
	// a front of darkness crosses the room where the light did, and the other
	// seven read as a bar instead of a strobe.
	//
	// The colour walks an ARCH, not a line: near white on the downbeat, down
	// through gold to deep orange at band 4, and back up to cream at band 8,
	// which hands off to band 1 with no jump.
	//
	// Softness 1.6 is crisp -- a tick needs an edge. No fade: every band runs the
	// whole reach at full strength, and the cycle restarts only when the last
	// one has crossed it.
	//
	// The 60 wake is carried as written. The shader only stretches a band when
	// the wake is longer than its thickness, so at these widths it draws
	// symmetric -- exactly as it does in GlowInTheDark.
	static void Unison()
	{
		Band(110.0, 1.6, 1.30, 60.0, 1, 0.0);
		Ambient(8, 0.35, 4096.0, 1);
		I("rss_ambient_org", 3);          // the map centre, which does not move
		I("rss_ambient_timing", 1);
		Train(128.0, 140);

		Flag("rss_perband", true);
		BandSlot(1, 0xFFF2D8, 260, 1);    // the downbeat
		BandSlot(2, 0xFFC24A, 110, 1);
		BandSlot(3, 0xFFA020, 110, 1);
		BandSlot(4, 0xFF7A12, 110, 1);    // the far point of the arch
		BandSlot(5, 0x07131C, 150, 3);    // the rest: crush, so this is a swatch
		BandSlot(6, 0xFF8C1E, 110, 1);
		BandSlot(7, 0xFFB43A, 110, 1);
		BandSlot(8, 0xFFD86E, 110, 1);    // and back, to hand off to band 1

		// THE LATTICE AS A RULER. Diamonds 96 apart, every fourth line bolder,
		// nothing drifting, lines only. Painted, never in the air: the air
		// lattice has no solution for a ring, so any air value here would be a
		// number that reads as doing something and does nothing.
		Fill(1, 96.0, 96.0, 2.5, 0.9, 0.0, 0.0);
		FillMotion(45.0, 0.0, 4.0, 2.2, 0.0, 0.0, 0.0, 0);
		RGB("rss_fill", 255, 208, 138);   // warm: the ruler belongs to the light
	}

	// ---- off ---------------------------------------------------------------

	// Not a look, an off. Intensity 0 stops the shader at its first gate.
	static void Off()
	{
		Band(26.0, 0.55, 0.0, 0.0, 1, 0.35);
		Ambient(0, 0.35, 900.0, 1);
	}

	// ---- quiet -------------------------------------------------------------

	// A slow swell breathing out from under you. The one that reads as the room
	// being alive rather than as an effect happening to it.
	static void Tide()
	{
		Band(64.0, 0.9, 0.55, 0.0, 1, 0.5);
		Ambient(2, 0.18, 1100.0, 1);
		RGB("rss_col", 90, 150, 210);
	}

	// Two bars walking the map, offset so one arrives as the other leaves.
	// Something scanning the level on a schedule.
	static void Patrol()
	{
		Band(34.0, 0.7, 0.75, 0.0, 1, 0.4);
		Ambient(2, 0.22, 1600.0, 2);
		RGB("rss_col", 150, 200, 170);
	}

	// A ping from you and nothing else -- equipment, not weather. Ambient is
	// deliberately off here; switch it on for both at once.
	//
	// THE PING ITSELF IS A SOURCE SWITCH, and presets never touch those, so
	// this shows nothing but fired bands until Sources > Ping is on. The menu
	// says so beside the preset.
	static void Sonar()
	{
		Band(22.0, 0.45, 1.15, 0.0, 1, 0.55);
		Ambient(0, 0.35, 900.0, 1);
		RGB("rss_col", 120, 255, 220);
		Fill(2, 90.0, 90.0, 2.0, 1.2, 0.6, 0.0);
	}

	// ---- reactive ----------------------------------------------------------

	// Nothing standing, everything fired. A ring off every kill and every
	// explosion, hard and brief.
	static void Shockwave()
	{
		Band(20.0, 0.35, 1.7, 0.0, 1, 0.6);
		Ambient(0, 0.35, 900.0, 1);
		Event(1.2, 992.0, 1.6, 1);          // 992 units in 0.75 s, as it always was
		RGB("rss_col", 255, 220, 150);
	}

	// Bars running the length of a corridor with a long wake behind them, so a
	// band reads as travelling rather than as appearing.
	static void Corridor()
	{
		Band(30.0, 0.6, 1.0, 72.0, 1, 0.35);
		Ambient(3, 0.30, 1500.0, 2);
		RGB("rss_col", 190, 210, 255);
		RGB("rss_col2", 90, 120, 255);
		F("rss_col_mix", 0.5);
	}

	// Shape 5: a horizontal plane climbing through the map, so a stairwell is
	// one front rising through it rather than four surfaces taking turns.
	// Nothing else here uses the vertical shape.
	static void Rising()
	{
		Band(48.0, 0.8, 0.95, 0.0, 1, 0.45);
		Ambient(2, 0.16, 700.0, 5);
		RGB("rss_col", 170, 140, 255);
		Fill(1, 64.0, 64.0, 2.0, 1.6, 0.5, 0.0);
	}

	// CRUSH: the band takes light AWAY rather than adding it, so a dark bar
	// sweeps the room. The only preset that subtracts, and much the most
	// unsettling of the set at low intensity.
	static void Dragnet()
	{
		Band(40.0, 0.7, 1.0, 0.0, 3, 0.4);
		Ambient(1, 0.24, 1300.0, 1);
		RGB("rss_col", 40, 30, 60);
	}

	// ---- loud --------------------------------------------------------------

	// A grid of light painted across every surface the band crosses. The
	// lattice is the point and the band is the excuse.
	static void Cage()
	{
		Band(90.0, 1.1, 1.15, 0.0, 1, 0.4);
		Ambient(2, 0.20, 1200.0, 1);
		RGB("rss_col", 60, 120, 180);
		RGB("rss_fill", 220, 245, 255);
		Fill(1, 40.0, 40.0, 2.5, 1.2, 0.18, 0.0);
		FillMotion(0, 6.0, 4.0, 2.4, 0.0, 0.10, 0.0, 0);
	}

	// The same cage, IN THE AIR. You walk through the grid instead of looking
	// at it on a wall. Nothing else in this family can do that.
	static void Hologram()
	{
		Band(120.0, 1.2, 1.05, 0.0, 1, 0.45);
		Ambient(2, 0.16, 1300.0, 4);
		RGB("rss_col", 70, 200, 220);
		RGB("rss_fill", 190, 255, 255);
		Fill(1, 44.0, 44.0, 2.0, 1.4, 0.10, 0.85);
		FillMotion(12.0, 10.0, 4.0, 2.2, 0.06, 0.12, 0.35, 1);
	}

	// Dots rather than lines, jittering and flickering hard, crossing into a
	// second colour as the band travels. A signal breaking up.
	static void Interference()
	{
		Band(80.0, 0.9, 1.25, 96.0, 1, 0.4);
		Ambient(3, 0.42, 1000.0, 1);
		RGB("rss_col", 120, 255, 180);
		RGB("rss_col2", 255, 60, 200);
		F("rss_col_mix", 0.75);
		RGB("rss_fill", 255, 255, 255);
		Fill(2, 26.0, 26.0, 3.0, 0.9, 0.05, 0.55);
		FillMotion(0, 22.0, 0, 2.0, 0.55, 0.65, 0.0, 0);
	}

	// Every source at once in one colour, fired hard. Kills and explosions
	// throw rings through a room that is already pulsing.
	static void Bloodrush()
	{
		Band(34.0, 0.5, 1.8, 48.0, 1, 0.5);
		Ambient(3, 0.5, 1000.0, 1);
		Event(1.62, 1440.0, 1.8, 4);        // 1440 units in 0.9 s
		RGB("rss_col", 255, 60, 50);
		RGB("rss_col2", 255, 170, 60);
		F("rss_col_mix", 0.6);
		Fill(2, 34.0, 34.0, 3.5, 0.8, 0.2, 0.4);
		FillMotion(0, 16.0, 0, 2.0, 0.3, 0.35, 0.0, 0);
	}

	// Five standing bands as SHELLS rather than rings, so they rise as they
	// expand, two colours, an air lattice and a long wake. The top of the range
	// and deliberately still readable -- everything is on a slider if you want
	// it worse than this.
	static void Carnival()
	{
		Band(70.0, 1.0, 1.5, 128.0, 1, 0.4);
		Ambient(5, 0.55, 1400.0, 4);
		Event(1.8, 1350.0, 1.5, 1);         // 1350 units in 1.2 s
		RGB("rss_col", 255, 120, 40);
		RGB("rss_col2", 60, 140, 255);
		F("rss_col_mix", 0.85);
		RGB("rss_fill", 255, 240, 200);
		Fill(1, 30.0, 30.0, 2.0, 1.0, 0.12, 0.7);
		FillMotion(25.0, 18.0, 3.0, 2.6, 0.25, 0.30, 0.5, 1);
	}

	// ---- 22-34: THE SAME LOOKS, CROSSING THE MAP ----------------------------
	//
	// Owner, 2026-09-18: "evertyhing crosses the map, nothing originates from
	// player. maybe we can keep a few 'originate from player' but i want the
	// other ones too."
	//
	// Each of these calls the preset it is named after -- so the band, the
	// colours, the lattice and the wake are that preset's, to the number -- and
	// then replaces ONLY its standing bands: a signed shape (6-9) instead of
	// rings or bars, the map centre instead of your feet, and the map's own span
	// instead of a reach. Nothing above this line changed, so Tide is still the
	// swell breathing out from under you, and Tide -- crossing is the same water
	// arriving from the west.
	//
	// The directions are spread across the set on purpose: a list where
	// everything travels west to east reads as one preset with thirteen
	// palettes. The speeds are lower than their originals, because the distance
	// is now the whole level rather than a reach around you.
	//
	// EVENT bands are left alone. A ring off an explosion belongs at the
	// explosion, not at the edge of the map.

	// A preset's standing bands, crossing. The reach is not passed: the handler
	// gives a signed shape the map's own span.
	static void Crossing(int count, double speed, int shape)
	{
		Ambient(count, speed, 4096.0, shape);
		I("rss_ambient_org", 3);
	}

	static void TideCross()         { Tide();         Crossing(1, 0.09, 6); }
	static void PatrolCross()       { Patrol();       Crossing(2, 0.14, 7); }
	static void CorridorCross()     { Corridor();     Crossing(3, 0.16, 6); }
	static void DragnetCross()      { Dragnet();      Crossing(1, 0.13, 9); }
	static void CageCross()         { Cage();         Crossing(1, 0.12, 8); }
	static void HologramCross()     { Hologram();     Crossing(1, 0.11, 7); }
	static void InterferenceCross() { Interference(); Crossing(2, 0.22, 6); }
	static void BloodrushCross()    { Bloodrush();    Crossing(2, 0.25, 9); }
	static void CarnivalCross()     { Carnival();     Crossing(3, 0.20, 8); }
	static void WallOfLightCross()  { WallOfLight();  Crossing(1, 0.10, 6); }
	static void WallOfDarkCross()   { WallOfDark();   Crossing(1, 0.09, 9); }
	static void WallOfColourCross() { WallOfColour(); Crossing(1, 0.10, 7); }
	static void WallOfFogCross()    { WallOfFog();    Crossing(1, 0.08, 8); }
}
