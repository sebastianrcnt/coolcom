// Input: keyboard and mouse events from the VM-only input FIFO
// (coolcom,coolvm-input, not present on a real M1; USB HID will replace it).
//
// FIFO protocol (tools/coolvm/README.md): a read of INPUT+0 gives the number of
// complete records; three reads of INPUT+4 return type, code, value of the
// oldest and pop it. The IRQ stays asserted while records remain. Records use
// Linux input numbers. Key events become TempleOS-style messages: ASCII plus a
// scan code (PS/2 set 1 numbering, 0x80 = E0 prefix) with SCF_* modifier flags.
#define EV_SYN       0
#define EV_KEY       1
#define EV_REL       2
#define REL_X        0
#define REL_Y        1
#define REL_WHEEL    8
#define BTN_LEFT     0x110
#define BTN_RIGHT    0x111
#define BTN_MIDDLE   0x112

#define SCF_E0_PREFIX 0x80
#define SCF_SHIFT     0x200
#define SCF_CTRL      0x400
#define SCF_ALT       0x800
#define SCF_CAPS      0x1000
#define SCF_NUM       0x2000
#define SCF_SCROLL    0x4000

#define KEY_LEFTCTRL   29
#define KEY_LEFTSHIFT  42
#define KEY_RIGHTSHIFT 54
#define KEY_C          46
#define KEY_LEFTALT    56
#define KEY_CAPSLOCK   58
#define KEY_NUMLOCK    69
#define KEY_SCROLLLOCK 70
#define KEY_RIGHTCTRL  97
#define KEY_RIGHTALT   100

#define KBD_BUF 256

class CKbdKey {I64 ascii, sc;};

CKbdKey kbd_buf[KBD_BUF];
I64 kbd_head, kbd_tail, kbd_lock, kbd_locks;  // kbd_locks: SCF_CAPS/NUM/SCROLL toggles
U8 kbd_down[256], kbd_norm[128], kbd_shift[128];

class CMouse {I64 mx, my, wheel, buttons;};  // x, y: pixels (clamped to the screen when there is one)

CMouse mouse;

U0 KbdMapRow(I64 code, U8 *lo, U8 *up)
{
    while (*lo) {
        kbd_norm[code] = *lo++;
        kbd_shift[code++] = *up++;
    }
}

U0 KbdMapInit()
{//US layout for Linux key codes 1..57.
    KbdMapRow(2, "1234567890-=", "!@#!%^&*()_+");
    KbdMapRow(16, "qwertyuiop[]", "QWERTYUIOP{}");
    KbdMapRow(30, "asdfghjkl;'", "ASDFGHJKL:'");
    KbdMapRow(44, "zxcvbnm,./", "ZXCVBNM<>?");
    kbd_shift[5] = 36;   // dollar sign
    kbd_shift[40] = 34;  // double quote
    kbd_norm[41] = 96;   // backtick
    kbd_shift[41] = 126; // tilde
    kbd_norm[43] = 92;   // backslash
    kbd_shift[43] = '|';
    kbd_norm[1] = kbd_shift[1] = 27;
    kbd_norm[14] = kbd_shift[14] = 8;
    kbd_norm[15] = kbd_shift[15] = 9;
    kbd_norm[28] = kbd_shift[28] = '\n';
    kbd_norm[57] = kbd_shift[57] = ' ';
}

I64 KbdScan(I64 code)
{//Linux key code -> TempleOS scan code (0 if unknown).
    if (code >= 1 && code <= 88)
        return code;
    switch (code) {
        case 96: return 0x1C | SCF_E0_PREFIX;  // keypad enter
        case 97: return 0x1D | SCF_E0_PREFIX;  // right ctrl
        case 98: return 0x35 | SCF_E0_PREFIX;  // keypad /
        case 100: return 0x38 | SCF_E0_PREFIX;  // right alt
        case 102: return 0x47 | SCF_E0_PREFIX;  // home
        case 103: return 0x48 | SCF_E0_PREFIX;  // up
        case 104: return 0x49 | SCF_E0_PREFIX;  // page up
        case 105: return 0x4B | SCF_E0_PREFIX;  // left
        case 106: return 0x4D | SCF_E0_PREFIX;  // right
        case 107: return 0x4F | SCF_E0_PREFIX;  // end
        case 108: return 0x50 | SCF_E0_PREFIX;  // down
        case 109: return 0x51 | SCF_E0_PREFIX;  // page down
        case 110: return 0x52 | SCF_E0_PREFIX;  // insert
        case 111: return 0x53 | SCF_E0_PREFIX;  // delete
    }
    return 0;
}

U0 KbdPush(I64 ascii, I64 sc)
{
    I64 daif = SpinLockIrq(&kbd_lock), next = (kbd_tail + 1) % KBD_BUF;
    if (next != kbd_head) {
        kbd_buf[kbd_tail].ascii = ascii;
        kbd_buf[kbd_tail].sc = sc;
        kbd_tail = next;
    }
    SpinUnlockIrq(&kbd_lock, daif);
}

I64 KbdMods()
{
    I64 m = kbd_locks;
    if (kbd_down[KEY_LEFTSHIFT] || kbd_down[KEY_RIGHTSHIFT])
        m |= SCF_SHIFT;
    if (kbd_down[KEY_LEFTCTRL] || kbd_down[KEY_RIGHTCTRL])
        m |= SCF_CTRL;
    if (kbd_down[KEY_LEFTALT] || kbd_down[KEY_RIGHTALT])
        m |= SCF_ALT;
    return m;
}

U0 KbdKey(I64 code, I64 value)
{//A key changed (value 0 up, 1 down, 2 repeat).
    I64 sc = KbdScan(code), ascii = 0, m;
    Bool letter;
    if (!sc || code > 255)
        return;
    if (!value) {
        kbd_down[code] = FALSE;
        return;
    }
    if (value == 1) {
        kbd_down[code] = TRUE;
        if (code == KEY_CAPSLOCK)
            kbd_locks ^= SCF_CAPS;
        else if (code == KEY_NUMLOCK)
            kbd_locks ^= SCF_NUM;
        else if (code == KEY_SCROLLLOCK)
            kbd_locks ^= SCF_SCROLL;
    }
    m = KbdMods;
    if (code == KEY_C && value == 1 && (m & SCF_CTRL) && (m & SCF_ALT)) {
        break_req = TRUE;  // TempleOS Ctrl+Alt+C: acted on in KExcept, which has the frame
        return;
    }
    if (code < 128) {
        if (m & SCF_SHIFT)
            ascii = kbd_shift[code];
        else
            ascii = kbd_norm[code];
        letter = (ascii >= 'a' && ascii <= 'z') || (ascii >= 'A' && ascii <= 'Z');
        if (letter && (m & SCF_CAPS))
            ascii ^= 0x20;
        if (letter && (m & SCF_CTRL))
            ascii = (ascii | 0x20) - 'a' + 1;
    }
    KbdPush(ascii, sc | m);
}

Bool KbdPop(I64 *ascii, I64 *sc)
{//Oldest key press, FALSE if none.
    Bool ok = FALSE;
    I64 daif = SpinLockIrq(&kbd_lock);
    if (kbd_head != kbd_tail) {
        *ascii = kbd_buf[kbd_head].ascii;
        *sc = kbd_buf[kbd_head].sc;
        kbd_head = (kbd_head + 1) % KBD_BUF;
        ok = TRUE;
    }
    SpinUnlockIrq(&kbd_lock, daif);
    return ok;
}

I64 KbdPending()
{
    return (kbd_tail + KBD_BUF - kbd_head) % KBD_BUF;
}

U0 MouseEvent(I64 type, I64 code, I64 value)
{
    I64 bit = 0;
    if (type == EV_REL) {
        if (code == REL_X)
            mouse.mx += value;
        else if (code == REL_Y)
            mouse.my += value;
        else if (code == REL_WHEEL)
            mouse.wheel += value;
        if (fb.base) {
            if (mouse.mx < 0) mouse.mx = 0;
            if (mouse.my < 0) mouse.my = 0;
            if (mouse.mx >= fb.w) mouse.mx = fb.w - 1;
            if (mouse.my >= fb.h) mouse.my = fb.h - 1;
        }
    } else {
        if (code == BTN_LEFT) bit = 1;
        if (code == BTN_RIGHT) bit = 2;
        if (code == BTN_MIDDLE) bit = 4;
        if (value)
            mouse.buttons |= bit;
        else
            mouse.buttons &= ~bit;
    }
}

U0 InputIrq(I64 irq)
{//Drain the FIFO into the keyboard buffer and mouse state.
    I64 type, code, value;
    while (ArchMmioRead32(fdt_input.base) > 0) {
        type = ArchMmioRead32(fdt_input.base + 4);
        code = ArchMmioRead32(fdt_input.base + 4);
        value = (ArchMmioRead32(fdt_input.base + 4) << 32) >> 32;  // sign-extend
        if (type == EV_KEY && code >= BTN_LEFT && code <= BTN_MIDDLE)
            MouseEvent(type, code, value);
        else if (type == EV_KEY)
            KbdKey(code, value);
        else if (type == EV_REL)
            MouseEvent(type, code, value);
    }
}

Bool InputInit()
{//FALSE if the FDT has no input device.
    if (!fdt_input.base)
        return FALSE;
    KbdMapInit;
    if (fb.base) {
        mouse.mx = fb.w / 2;
        mouse.my = fb.h / 2;
    }
    IrqSet(fdt_input.irq, &InputIrq);
    return TRUE;
}

// Scan codes (with SCF_E0_PREFIX) of the editing keys.
#define SC_HOME  0xC7
#define SC_UP    0xC8
#define SC_LEFT  0xCB
#define SC_RIGHT 0xCD
#define SC_END   0xCF
#define SC_DOWN  0xD0
#define SC_DEL   0xD3

I64 uart_pend = -1;  // a byte read ahead while looking for an escape sequence

I64 UartRx()
{
    I64 a = uart_pend;
    if (a >= 0) {
        uart_pend = -1;
        return a;
    }
    return UartGet;
}

I64 UartRxWait(I64 ms)
{//A UART byte, or -1 if none arrives within ms.
    I64 deadline = ArchCntVct + ArchCntFrq * ms / 1000, a;
    while ((a = UartRx) < 0 && ArchCntVct < deadline) {}
    return a;
}

I64 UartEsc(I64 *sc)
{//After ESC from the terminal: ESC [ A/B/C/D/H/F and ESC [ n ~ (arrows, Home, End, Delete)
    //become *sc and return 0; anything else is a plain Escape.
    I64 b = UartRxWait(20), n = 0;
    *sc = 0;
    if (b != '[' && b != 'O') {
        uart_pend = b;
        return 27;
    }
    b = UartRxWait(20);
    while (b >= '0' && b <= '9') {
        n = n * 10 + b - '0';
        b = UartRxWait(20);
    }
    if (b == 'A')
        *sc = SC_UP;
    else if (b == 'B')
        *sc = SC_DOWN;
    else if (b == 'C')
        *sc = SC_RIGHT;
    else if (b == 'D')
        *sc = SC_LEFT;
    else if (b == 'H' || (b == '~' && (n == 1 || n == 7)))
        *sc = SC_HOME;
    else if (b == 'F' || (b == '~' && (n == 4 || n == 8)))
        *sc = SC_END;
    else if (b == '~' && n == 3)
        *sc = SC_DEL;
    return 0;
}

I64 GetKey(I64 *sc = NULL, Bool echo = TRUE)
{//Wait for a key press; returns its ASCII (0 for keys without one) and, if sc, the scan code with SCF_ flags.
    I64 a, s;
    while (!KbdPop(&a, &s)) {
        a = UartRx;  // the host terminal types into the UART
        if (a >= 0) {
            s = 0;
            if (a == '\r')
                a = '\n';
            else if (a == 27)
                a = UartEsc(&s);
            break;
        }
        Yield;
        ArchWfi;
    }
    if (sc)
        *sc = s;
    if (echo && a)
        ConsPut(a);
    return a;
}

I64 GetChar(I64 *sc = NULL, Bool echo = TRUE)
{//Wait for a key press that has an ASCII code.
    I64 a, s;
    do {
        a = GetKey(&s, FALSE);
    } while (!a);
    if (sc)
        *sc = s;
    if (echo)
        ConsPut(a);
    return a;
}

// ---- GetLine: a line editor with history ----
#define HIST_N   32
#define HIST_LEN 512
U8 kbd_hist[HIST_N * HIST_LEN];
U8 hist_edit[HIST_LEN];  // the line being typed while a history entry is shown
I64 hist_n, hist_head;   // entries kept; next slot to write

U8 *HistGet(I64 back)
{//The back-th newest entry (1 = newest).
    return kbd_hist + ((hist_head - back + 2 * HIST_N) % HIST_N) * HIST_LEN;
}

U0 HistAdd(U8 *line)
{
    if (!*line || (hist_n && !StrCmp(HistGet(1), line)))
        return;
    StrCpy(kbd_hist + hist_head * HIST_LEN, line);
    hist_head = (hist_head + 1) % HIST_N;
    if (hist_n < HIST_N)
        hist_n++;
}

// The line is UTF-8 in b[0..n); pos is a byte offset on a character boundary.
// The screen is kept in step with ConsPut(8) (backspace) and reprinting
// characters, which both the UART terminal and the framebuffer understand.
I64 LineWidth(U8 *b, I64 from, I64 to)
{//Terminal columns of b[from..to).
    I64 w = 0, k;
    while (from < to) {
        k = Utf8Len(b[from]);
        if (!k || from + k > to)
            k = 1;
        w += Utf8Width(Utf8Cp(b + from, k));
        from += k;
    }
    return w;
}

I64 LinePrev(U8 *b, I64 pos)
{//Start of the character before pos.
    if (pos > 0)
        pos--;
    while (pos > 0 && (b[pos] & 0xC0) == 0x80)
        pos--;
    return pos;
}

I64 LineNext(U8 *b, I64 pos, I64 n)
{//End of the character at pos.
    I64 k = Utf8Len(b[pos]);
    if (!k)
        k = 1;
    if (pos + k > n)
        k = n - pos;
    return pos + k;
}

U0 LineOut(U8 *b, I64 from, I64 to)
{
    while (from < to)
        ConsPut(b[from++]);
}

U0 LineBack(I64 cols)
{
    while (cols-- > 0)
        ConsPut(8);
}

U0 LineBlank(I64 cols)
{
    while (cols-- > 0)
        ConsPut(' ');
}

U0 LineSet(U8 *b, I64 size, I64 *_n, I64 *_pos, U8 *s)
{//Replace the whole line with s.
    I64 w;
    LineOut(b, *_pos, *_n);
    w = LineWidth(b, 0, *_n);
    LineBack(w);
    LineBlank(w);
    LineBack(w);
    *_n = StrLen(s);
    if (*_n > size - 1)
        *_n = size - 1;
    MemCpy(b, s, *_n);
    b[*_n] = 0;
    LineOut(b, 0, *_n);
    *_pos = *_n;
}

U0 LineInsert(U8 *b, I64 size, I64 *_n, I64 *_pos, U8 *ch, I64 k)
{//Insert the k bytes of one character at the cursor.
    I64 i, n = *_n, pos = *_pos;
    if (n + k > size - 1)
        return;
    for (i = n; i >= pos; i--)  // slide the tail up, including the NUL
        b[i + k] = b[i];
    MemCpy(b + pos, ch, k);
    n += k;
    LineOut(b, pos, n);
    pos += k;
    LineBack(LineWidth(b, pos, n));
    *_n = n;
    *_pos = pos;
}

U0 LineDelete(U8 *b, I64 *_n, I64 *_pos, I64 from, I64 to)
{//Delete b[from..to), the character just before or at the cursor, and redraw.
    I64 n = *_n, w = LineWidth(b, from, to), i;
    for (i = to; i <= n; i++)
        b[i - (to - from)] = b[i];
    n -= to - from;
    if (from < *_pos)  // backspace: the cursor moves back over it first
        LineBack(w);
    LineOut(b, from, n);
    LineBlank(w);
    LineBack(LineWidth(b, from, n) + w);
    *_n = n;
    *_pos = from;
}

U8 *GetLine(U8 *buf, I64 size)
{//Read a line with editing (Left/Right/Home/End, Backspace and Delete at the cursor, UTF-8),
    //and Up/Down through the history of earlier lines.
    I64 n = 0, pos = 0, hi = 0, c, sc, key, u8k = 0, u8n = 0, e;
    U8 ubuf[8];
    if (size > HIST_LEN)
        size = HIST_LEN;
    buf[0] = 0;
    while (TRUE) {
        c = GetKey(&sc, FALSE);
        key = sc & 0xFF;
        if (c == '\n')
            break;
        if (!c) {
            if (key == SC_LEFT) {
                if (pos > 0) {
                    e = LinePrev(buf, pos);
                    LineBack(LineWidth(buf, e, pos));
                    pos = e;
                }
            } else if (key == SC_RIGHT) {
                if (pos < n) {
                    e = LineNext(buf, pos, n);
                    LineOut(buf, pos, e);
                    pos = e;
                }
            } else if (key == SC_HOME) {
                LineBack(LineWidth(buf, 0, pos));
                pos = 0;
            } else if (key == SC_END) {
                LineOut(buf, pos, n);
                pos = n;
            } else if (key == SC_DEL) {
                if (pos < n)
                    LineDelete(buf, &n, &pos, pos, LineNext(buf, pos, n));
            } else if (key == SC_UP) {
                if (hi < hist_n) {
                    if (!hi)
                        StrCpy(hist_edit, buf);
                    hi++;
                    LineSet(buf, size, &n, &pos, HistGet(hi));
                }
            } else if (key == SC_DOWN) {
                if (hi > 0) {
                    hi--;
                    if (hi)
                        LineSet(buf, size, &n, &pos, HistGet(hi));
                    else
                        LineSet(buf, size, &n, &pos, hist_edit);
                }
            }
            u8n = 0;
        } else if (c == 8 || c == 127) {
            if (pos > 0)
                LineDelete(buf, &n, &pos, LinePrev(buf, pos), pos);
            u8n = 0;
        } else if (c == 1) {  // Ctrl+A
            LineBack(LineWidth(buf, 0, pos));
            pos = 0;
        } else if (c == 5) {  // Ctrl+E
            LineOut(buf, pos, n);
            pos = n;
        } else if (c >= 32 && c < 127) {
            ubuf[0] = c;
            LineInsert(buf, size, &n, &pos, ubuf, 1);
            u8n = 0;
        } else if (c >= 0x80) {  // collect one UTF-8 sequence, then insert it whole
            if (Utf8Len(c) > 1) {
                ubuf[0] = c;
                u8n = 1;
                u8k = Utf8Len(c);
            } else if (u8n > 0 && u8n < u8k && (c & 0xC0) == 0x80) {
                ubuf[u8n++] = c;
                if (u8n == u8k) {
                    LineInsert(buf, size, &n, &pos, ubuf, u8k);
                    u8n = 0;
                }
            } else
                u8n = 0;
        } else
            u8n = 0;
    }
    LineOut(buf, pos, n);
    ConsPut('\n');
    buf[n] = 0;
    HistAdd(buf);
    return buf;
}

U8 *GetStr(U8 *buf, I64 size, Bool echo = TRUE)
{//Read a line into buf (at most size-1 chars) with echo and backspace editing.
    I64 n = 0, c;
    while (TRUE) {
        c = GetChar(NULL, FALSE);
        if (c == '\n')
            break;
        if (c == 8 || c == 127) {
            if (n > 0) {
                n--;
                if (echo) {
                    ConsPut(8);
                    ConsPut(' ');
                    ConsPut(8);
                }
            }
        } else if (c >= 32 && c < 127 && n < size - 1) {
            buf[n++] = c;
            if (echo)
                ConsPut(c);
        }
    }
    if (echo)
        ConsPut('\n');
    buf[n] = 0;
    return buf;
}
