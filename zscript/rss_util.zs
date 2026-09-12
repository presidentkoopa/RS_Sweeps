// RS_Sweeps -- shared helpers.
//
// Same shape as GITD_Util, RSD's, RSF and RSFL. These mods merge eventually and
// the copies collapse into one, which is only painless if they have not
// drifted.

class RSS
{
	clearscope static double GetF(String n, double def = 0.0)
	{
		let c = CVar.FindCVar(n); return c ? c.GetFloat() : def;
	}
	clearscope static int GetI(String n, int def = 0)
	{
		let c = CVar.FindCVar(n); return c ? c.GetInt() : def;
	}
	clearscope static bool GetB(String n, bool def = false)
	{
		let c = CVar.FindCVar(n); return c ? c.GetBool() : def;
	}
	clearscope static String GetS(String n, String def = "")
	{
		let c = CVar.FindCVar(n); return c ? c.GetString() : def;
	}
	clearscope static void SetF(String n, double v)
	{
		let c = CVar.FindCVar(n); if (c) c.SetFloat(v);
	}
	clearscope static void SetI(String n, int v)
	{
		let c = CVar.FindCVar(n); if (c) c.SetInt(v);
	}

	// ---- WHAT ELSE IS LOADED ------------------------------------------------
	//
	// SOFT detection, never a hard link. FindClass is a RUNTIME lookup by name,
	// so naming a class here does NOT make it a compile-time dependency -- this
	// mod still builds and runs with none of the others present, and the answer
	// is simply false.
	//
	// That is the difference between "unlocks more when you have it" and "will
	// not start without it". An earlier draft of the effects file held a real
	// typed reference to a monster class, which made a LIGHTING mod refuse to
	// compile unless a MONSTER mod was loaded. This is the fix for that whole
	// category, not just that one case.
	//
	// The sweep itself never calls into any of them. Acting on what the front
	// crosses goes through Actor.OnSweepCrossed, which every actor has. These
	// checks exist so the MENU can say what is available and so an effect can
	// be skipped rather than silently doing nothing.

	// RS_Main -- the monster tier ladder. Unlocks the retier options.
	clearscope static bool HasMonsterTiers()
	{
		// Through a String VARIABLE deliberately. Assigning a class from a
		// string is a runtime lookup that yields null for a name nothing
		// defines -- which is the whole point -- and going via a variable
		// keeps it a runtime lookup rather than something the compiler might
		// try to resolve while parsing.
		String n = "RS_MonsterMaster";
		Class<Actor> c = n;
		return c != null;
	}

	// RS_Fog -- unlocks the fog effects.
	clearscope static bool HasFog()
	{
		return CVar.FindCVar("rsf_enabled") != null;
	}

	// RS_GlowInTheDark -- unlocks the glow effects.
	clearscope static bool HasGlow()
	{
		return CVar.FindCVar("gitd_enabled") != null;
	}

	// RS_Darkness -- unlocks the darkness effects.
	clearscope static bool HasDarkness()
	{
		return CVar.FindCVar("rsd_enabled") != null;
	}

	// ALWAYS alpha 255. A colour that loses its alpha is the most expensive bug
	// in this family -- several draw paths gate on `.a > 0` and simply stop,
	// with no error anywhere.
	clearscope static Color RGB(String pre, int dr = 255, int dg = 255, int db = 255)
	{
		return Color(255,
			clamp(GetI(pre .. "_r", dr), 0, 255),
			clamp(GetI(pre .. "_g", dg), 0, 255),
			clamp(GetI(pre .. "_b", db), 0, 255));
	}

	// A `color` cvar, read packed. Same rule: alpha 255. Split by hand because
	// Color(int) does not convert on this engine -- it compiles and then fails
	// at load, which GlowInTheDark paid for once already.
	clearscope static Color Packed(String n, int def = 0xFFFFFF)
	{
		int p = GetI(n, def);
		return Color(255, (p >> 16) & 255, (p >> 8) & 255, p & 255);
	}
}
