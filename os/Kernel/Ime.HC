// Hangul input for the VM window's keyboard (Input.HC): 2-beolsik composition. The UART
// stays as it is (the host terminal composes there).
//
// Shift+Space, the Hangul key, or Right Alt pressed and released alone toggles ime_on. With
// it on, the letter keys type jamo, and the syllable being composed (the preedit) is kept on
// screen and rewritten as keys arrive: every step queues a Backspace and the new text, which
// any reader of key events (GetLine, the shell, Vim's insert mode) already handles. Backspace
// takes the last jamo off the syllable. Any other key ends the composition first.
//
// The keyboard layout, q..p a..l z..m as jamo (Shift: ㅃ ㅉ ㄸ ㄲ ㅆ ㅒ ㅖ for q w e r t o p):
//   q ㅂ  w ㅈ  e ㄷ  r ㄱ  t ㅅ  y ㅛ  u ㅕ  i ㅑ  o ㅐ  p ㅔ
//   a ㅁ  s ㄴ  d ㅇ  f ㄹ  g ㅎ  h ㅗ  j ㅓ  k ㅏ  l ㅣ
//   z ㅋ  x ㅌ  c ㅊ  v ㅍ  b ㅠ  n ㅜ  m ㅡ
// Jamo are held as Unicode compatibility jamo (U+3131..U+3163). A syllable is
// U+AC00 + (initial * 21 + medial) * 28 + final.
#define IME_JAMO_FIRST 0x3131
#define IME_VOWEL_FIRST 0x314F

Bool ime_on;
I64 ime_l, ime_v, ime_t;     // the syllable being composed: initial, medial, final (0: none)
Bool ime_shown;              // the composed text is on the screen as one character
Bool ime_alt_clean;          // Right Alt went down and nothing else since
I8 ime_cho[30], ime_jong[30]; // by jamo - U+3131: initial and final index (-1: cannot)
Bool ime_ready;

U0 ImeInit()
{
    I64 i;
    for (i = 0; i < 30; i++) ime_cho[i] = ime_jong[i] = -1;
    // initial consonants (19), final consonants and clusters (1..27)
    ime_cho[0x3131 - 0x3131] = 0; ime_cho[0x3132 - 0x3131] = 1; ime_cho[0x3134 - 0x3131] = 2;
    ime_cho[0x3137 - 0x3131] = 3; ime_cho[0x3138 - 0x3131] = 4; ime_cho[0x3139 - 0x3131] = 5;
    ime_cho[0x3141 - 0x3131] = 6; ime_cho[0x3142 - 0x3131] = 7; ime_cho[0x3143 - 0x3131] = 8;
    ime_cho[0x3145 - 0x3131] = 9; ime_cho[0x3146 - 0x3131] = 10; ime_cho[0x3147 - 0x3131] = 11;
    ime_cho[0x3148 - 0x3131] = 12; ime_cho[0x3149 - 0x3131] = 13; ime_cho[0x314A - 0x3131] = 14;
    ime_cho[0x314B - 0x3131] = 15; ime_cho[0x314C - 0x3131] = 16; ime_cho[0x314D - 0x3131] = 17;
    ime_cho[0x314E - 0x3131] = 18;
    ime_jong[0x3131 - 0x3131] = 1; ime_jong[0x3132 - 0x3131] = 2; ime_jong[0x3133 - 0x3131] = 3;
    ime_jong[0x3134 - 0x3131] = 4; ime_jong[0x3135 - 0x3131] = 5; ime_jong[0x3136 - 0x3131] = 6;
    ime_jong[0x3137 - 0x3131] = 7; ime_jong[0x3139 - 0x3131] = 8; ime_jong[0x313A - 0x3131] = 9;
    ime_jong[0x313B - 0x3131] = 10; ime_jong[0x313C - 0x3131] = 11; ime_jong[0x313D - 0x3131] = 12;
    ime_jong[0x313E - 0x3131] = 13; ime_jong[0x313F - 0x3131] = 14; ime_jong[0x3140 - 0x3131] = 15;
    ime_jong[0x3141 - 0x3131] = 16; ime_jong[0x3142 - 0x3131] = 17; ime_jong[0x3144 - 0x3131] = 18;
    ime_jong[0x3145 - 0x3131] = 19; ime_jong[0x3146 - 0x3131] = 20; ime_jong[0x3147 - 0x3131] = 21;
    ime_jong[0x3148 - 0x3131] = 22; ime_jong[0x314A - 0x3131] = 23; ime_jong[0x314B - 0x3131] = 24;
    ime_jong[0x314C - 0x3131] = 25; ime_jong[0x314D - 0x3131] = 26; ime_jong[0x314E - 0x3131] = 27;
    ime_ready = TRUE;
}

I64 ImeJamo(I64 letter, Bool shift)
{//The jamo a letter key (a..z) types; 0 if none.
    switch (letter) {
        case 'q': if (shift) return 0x3143; return 0x3142;
        case 'w': if (shift) return 0x3149; return 0x3148;
        case 'e': if (shift) return 0x3138; return 0x3137;
        case 'r': if (shift) return 0x3132; return 0x3131;
        case 't': if (shift) return 0x3146; return 0x3145;
        case 'y': return 0x315B;
        case 'u': return 0x3155;
        case 'i': return 0x3151;
        case 'o': if (shift) return 0x3152; return 0x3150;
        case 'p': if (shift) return 0x3156; return 0x3154;
        case 'a': return 0x3141;
        case 's': return 0x3134;
        case 'd': return 0x3147;
        case 'f': return 0x3139;
        case 'g': return 0x314E;
        case 'h': return 0x3157;
        case 'j': return 0x3153;
        case 'k': return 0x314F;
        case 'l': return 0x3163;
        case 'z': return 0x314B;
        case 'x': return 0x314C;
        case 'c': return 0x314A;
        case 'v': return 0x314D;
        case 'b': return 0x3160;
        case 'n': return 0x315C;
        case 'm': return 0x3161;
    }
    return 0;
}

I64 ImeVowelJoin(I64 a, I64 b)
{//Two vowels typed in a row that make one: ㅗ+ㅏ = ㅘ, ...; 0 if not.
    if (a == 0x3157) {
        if (b == 0x314F) return 0x3158;
        if (b == 0x3150) return 0x3159;
        if (b == 0x3163) return 0x315A;
    } else if (a == 0x315C) {
        if (b == 0x3153) return 0x315D;
        if (b == 0x3154) return 0x315E;
        if (b == 0x3163) return 0x315F;
    } else if (a == 0x3161 && b == 0x3163)
        return 0x3162;
    return 0;
}

I64 ImeVowelFirst(I64 v)
{//The vowel left after deleting the last key of a two-key vowel; 0 for a single one.
    switch (v) {
        case 0x3158: case 0x3159: case 0x315A: return 0x3157;
        case 0x315D: case 0x315E: case 0x315F: return 0x315C;
        case 0x3162: return 0x3161;
    }
    return 0;
}

I64 ImeFinalJoin(I64 a, I64 b)
{//Two final consonants that make a cluster (ㄱ+ㅅ = ㄳ, ...); 0 if not.
    if (a == 0x3131 && b == 0x3145) return 0x3133;
    if (a == 0x3134) {
        if (b == 0x3148) return 0x3135;
        if (b == 0x314E) return 0x3136;
    }
    if (a == 0x3139) {
        if (b == 0x3131) return 0x313A;
        if (b == 0x3141) return 0x313B;
        if (b == 0x3142) return 0x313C;
        if (b == 0x3145) return 0x313D;
        if (b == 0x314C) return 0x313E;
        if (b == 0x314D) return 0x313F;
        if (b == 0x314E) return 0x3140;
    }
    if (a == 0x3142 && b == 0x3145) return 0x3144;
    return 0;
}

I64 ImeFinalSplit(I64 t, I64 *_second)
{//A cluster final into its two consonants (returns the first); a single one returns 0.
    *_second = 0;
    switch (t) {
        case 0x3133: *_second = 0x3145; return 0x3131;
        case 0x3135: *_second = 0x3148; return 0x3134;
        case 0x3136: *_second = 0x314E; return 0x3134;
        case 0x313A: *_second = 0x3131; return 0x3139;
        case 0x313B: *_second = 0x3141; return 0x3139;
        case 0x313C: *_second = 0x3142; return 0x3139;
        case 0x313D: *_second = 0x3145; return 0x3139;
        case 0x313E: *_second = 0x314C; return 0x3139;
        case 0x313F: *_second = 0x314D; return 0x3139;
        case 0x3140: *_second = 0x314E; return 0x3139;
        case 0x3144: *_second = 0x3145; return 0x3142;
    }
    return 0;
}

I64 ImeSyllable(I64 l, I64 v, I64 t)
{
    I64 j = 0;
    if (t) j = ime_jong[t - IME_JAMO_FIRST];
    return 0xAC00 + (ime_cho[l - IME_JAMO_FIRST] * 21 + (v - IME_VOWEL_FIRST)) * 28 + j;
}

I64 ImePreedit()
{//The composed text as one code point; 0 if nothing is being composed.
    if (ime_l && ime_v) return ImeSyllable(ime_l, ime_v, ime_t);
    if (ime_l) return ime_l;
    return ime_v;
}

U0 ImeEnd()
{//Leave what is on the screen as it is.
    ime_l = ime_v = ime_t = 0;
    ime_shown = FALSE;
}

U0 ImeShow(I64 fixed)
{//Replace the preedit on screen by fixed (if any) and the new preedit.
    I64 p = ImePreedit;
    if (ime_shown)
        KeyPush(KEY_BACKSPACE);
    if (fixed)
        KeyPush(fixed);
    if (p)
        KeyPush(p);
    ime_shown = p != 0;
}

U0 ImeType(I64 jamo)
{//One jamo key. The automaton: a consonant after a syllable becomes its final if it can,
    //a vowel after a final takes that consonant (or the last one of a cluster) as its initial.
    I64 fixed = 0, c, second, first;
    Bool cons = jamo < IME_VOWEL_FIRST;
    if (!ime_ready)
        ImeInit;
    if (!ime_l && !ime_v) {
        if (cons) ime_l = jamo;
        else ime_v = jamo;
    } else if (ime_l && !ime_v) {
        if (cons) {fixed = ime_l; ime_l = jamo;}
        else ime_v = jamo;
    } else if (!ime_l) {
        if (cons) {fixed = ime_v; ime_v = 0; ime_l = jamo;}
        else if (c = ImeVowelJoin(ime_v, jamo)) ime_v = c;
        else {fixed = ime_v; ime_v = jamo;}
    } else if (!ime_t) {
        if (cons) {
            if (ime_jong[jamo - IME_JAMO_FIRST] > 0) ime_t = jamo;
            else {fixed = ImeSyllable(ime_l, ime_v, 0); ime_l = jamo; ime_v = 0;}
        } else if (c = ImeVowelJoin(ime_v, jamo)) ime_v = c;
        else {fixed = ImeSyllable(ime_l, ime_v, 0); ime_l = 0; ime_v = jamo;}
    } else if (cons) {
        if (c = ImeFinalJoin(ime_t, jamo)) ime_t = c;
        else {fixed = ImeSyllable(ime_l, ime_v, ime_t); ime_l = jamo; ime_v = ime_t = 0;}
    } else {
        first = ImeFinalSplit(ime_t, &second);
        if (first) {
            fixed = ImeSyllable(ime_l, ime_v, first);
            ime_l = second;
        } else {
            fixed = ImeSyllable(ime_l, ime_v, 0);
            ime_l = ime_t;
        }
        ime_v = jamo;
        ime_t = 0;
    }
    ImeShow(fixed);
}

U0 ImeBackspace()
{//Take the last jamo off the syllable being composed.
    I64 second, first;
    if (ime_t) {
        first = ImeFinalSplit(ime_t, &second);
        ime_t = first;
    } else if (ime_v) {
        ime_v = ImeVowelFirst(ime_v);
    } else
        ime_l = 0;
    ImeShow(0);
}

Bool ImeComposing() {return ime_l || ime_v;}

U0 Ime(Bool on)
{//Turn Hangul input on or off (Shift+Space does the same from the keyboard).
    ImeEnd;
    ime_on = on;
}
