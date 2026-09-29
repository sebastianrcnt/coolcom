// A string constant is a U8 *: indexing it loads one byte ("AB"[0] once read 0x4241).
I64i StringIndexSum() {return "\101\e" [0] + "\101\e" [1] + "AB" [0] * 1000;}
