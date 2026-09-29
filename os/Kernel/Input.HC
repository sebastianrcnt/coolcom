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

I64 GetKey(I64 *sc = NULL, Bool echo = TRUE)
{//Wait for a key press; returns its ASCII (0 for keys without one) and, if sc, the scan code with SCF_ flags.
    I64 a, s;
    while (!KbdPop(&a, &s)) {
        a = UartGet;  // the host terminal types into the UART
        if (a >= 0) {
            if (a == '\r')
                a = '\n';
            s = 0;
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
