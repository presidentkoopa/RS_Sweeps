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
	const COUNT = 21;

	static void F(String n, double v) { let c = CVar.FindCVar(n); if (c) c.SetFloat(v); }
	static void I(String n, int v)    { let c = CVar.FindCVar(n); if (c) c.SetInt(v); }

	static void RGB(String pre, int r, int g, int b)
	{
		I(pre .. "_r", r); I(pre .. "_g", g); I(pre .. "_b", b);
	}

	// The band itself.
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

	// What a fired band does.
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
		Band(220.0, 2.2, 1.0, 1.2, 3, 0.35);
		Ambient(1, 0.10, 1800.0, 2);
		Event(2.6, 1500.0, 0.9, 2);
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
	// A signed shape ignores the origin and reach settings. The handler puts
	// the band off the near edge and gives it the map's own span, because a
	// sweep that starts in the middle or stops halfway is not one.

	// The plain one. A single front crossing the level west to east, slowly
	// enough that you watch it come.
	static void Sweep()
	{
		Band(70.0, 1.0, 1.1, 1.4, 1, 0.15);
		Ambient(1, 0.10, 4096.0, 6);
		RGB("rss_col", 120, 200, 255);
		RGB("rss_col2", 255, 140, 60);
		F("rss_col_mix", 0.8);
	}

	// The same, coming back the other way, and north to south rather than east
	// to west so two of these running together cross.
	static void Sweepback()
	{
		Band(70.0, 1.0, 1.1, 1.4, 1, 0.15);
		Ambient(1, 0.10, 4096.0, 9);
		RGB("rss_col", 255, 140, 60);
		RGB("rss_col2", 120, 200, 255);
		F("rss_col_mix", 0.8);
	}

	// A front that takes the light with it. Crush, so the level goes dark
	// behind it rather than lighting up -- pair it with the darkness or the
	// retier effect and it is a wave that changes the map as it passes.
	static void Purge()
	{
		Band(110.0, 1.4, 1.2, 2.0, 3, 0.1);
		Ambient(1, 0.07, 4096.0, 6);
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
		}
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
	static void Sonar()
	{
		Band(22.0, 0.45, 1.15, 0.6, 1, 0.55);
		Ambient(0, 0.35, 900.0, 1);
		RGB("rss_col", 120, 255, 220);
		Fill(2, 90.0, 90.0, 2.0, 1.2, 0.6, 0.0);
	}

	// ---- reactive ----------------------------------------------------------

	// Nothing standing, everything fired. A ring off every kill and every
	// explosion, hard and brief.
	static void Shockwave()
	{
		Band(20.0, 0.35, 1.7, 0.9, 1, 0.6);
		Ambient(0, 0.35, 900.0, 1);
		Event(0.75, 620.0, 1.6, 1);
		RGB("rss_col", 255, 220, 150);
	}

	// Bars running the length of a corridor with a long wake behind them, so a
	// band reads as travelling rather than as appearing.
	static void Corridor()
	{
		Band(30.0, 0.6, 1.0, 2.4, 1, 0.35);
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
		Band(80.0, 0.9, 1.25, 1.2, 1, 0.4);
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
		Band(34.0, 0.5, 1.8, 1.4, 1, 0.5);
		Ambient(3, 0.5, 1000.0, 1);
		Event(0.9, 800.0, 1.8, 4);
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
		Band(70.0, 1.0, 1.5, 1.8, 1, 0.4);
		Ambient(5, 0.55, 1400.0, 4);
		Event(1.2, 900.0, 1.5, 1);
		RGB("rss_col", 255, 120, 40);
		RGB("rss_col2", 60, 140, 255);
		F("rss_col_mix", 0.85);
		RGB("rss_fill", 255, 240, 200);
		Fill(1, 30.0, 30.0, 2.0, 1.0, 0.12, 0.7);
		FillMotion(25.0, 18.0, 3.0, 2.6, 0.25, 0.30, 0.5, 1);
	}
}
