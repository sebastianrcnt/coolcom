// Formatted printing: Print(), StrPrint() and the bare-string statement form.
// Varargs: Aiwnios passes `...` functions implicit argc and argv (I64 slots).
// Format-flag semantics follow Aiwnios/TempleOS StrPrint.HC (BSD-3).

// Emit one char: into *dst (then advance) or, if dst is NULL, to the UART.
U0 SPutCh(U8 **dst, U8 c)
{
  if (dst) {
    **dst = c;
    *dst += 1;
  } else
    UartPut(c);
}

// Emit `n` copies of c.
U0 SPutPad(U8 **dst, U8 c, I64 n)
{
  while (n-- > 0)
    SPutCh(dst, c);
}

// Emit s (len chars) padded to width. `pre` (sign/0x) goes before zero padding.
U0 SPutField(U8 **dst, U8 *pre, U8 *s, I64 len, I64 width, Bool left, Bool zero)
{
  I64 plen = 0, pad;
  while (pre[plen])
    plen++;
  pad = width - plen - len;
  if (pad < 0)
    pad = 0;
  if (!left && !zero)
    SPutPad(dst, ' ', pad);
  while (*pre)
    SPutCh(dst, *pre++);
  if (!left && zero)
    SPutPad(dst, '0', pad);
  while (len-- > 0)
    SPutCh(dst, *s++);
  if (left)
    SPutPad(dst, ' ', pad);
}

// Convert unsigned v in `radix` ending at `end`; returns start of digits.
U8 *SUtoA(U8 *end, U64 v, I64 radix, Bool upper)
{
  U8 *p = end;
  I64 d;
  *p = 0;
  do {
    d = v % radix;
    v = v / radix;
    if (d < 10)
      *--p = '0' + d;
    else if (upper)
      *--p = 'A' + d - 10;
    else
      *--p = 'a' + d - 10;
  } while (v);
  return p;
}

// Core formatter. dst==NULL prints to the UART, else writes *dst and NUL-terminates.
// Supports %[-0][width|*][.prec]{d,i,u,x,X,o,b,c,s,p,f,%}; l/h/z prefixes ignored.
U0 KFmt(U8 **dst, U8 *fmt, I64 argc, I64 *argv)
{
  U8 buf[80], *end = buf + 79, *p, *s, pre[4];
  I64 cur = 0, width, prec, ch, len, radix, i;
  U64 v;
  Bool left, zero, upper, sgn;
  F64 fv, frac;
  while (ch = *fmt++) {
    if (ch != '%') {
      SPutCh(dst, ch);
      goto next;   // HolyC has no continue
    }
    left = FALSE;
    zero = FALSE;
    width = 0;
    prec = -1;
    while (TRUE) {
      if (*fmt == '-')
        left = TRUE;
      else if (*fmt == '0')
        zero = TRUE;
      else
        break;
      fmt++;
    }
    if (*fmt == '*') {
      fmt++;
      width = argv[cur++];
      if (width < 0) {
        left = TRUE;
        width = -width;
      }
    } else
      while ('0' <= *fmt <= '9')
        width = width * 10 + *fmt++ - '0';
    if (*fmt == '.') {
      fmt++;
      prec = 0;
      if (*fmt == '*') {
        fmt++;
        prec = argv[cur++];
      } else
        while ('0' <= *fmt <= '9')
          prec = prec * 10 + *fmt++ - '0';
    }
    while (*fmt == 'l' || *fmt == 'h' || *fmt == 't' || *fmt == 'z')
      fmt++;
    ch = *fmt++;
    pre[0] = 0;
    upper = FALSE;
    sgn = FALSE;
    radix = 10;
    switch (ch) {
      case 0:
        if (dst)
          **dst = 0;
        return;
      case '%':
        SPutCh(dst, '%');
        break;
      case 'c':
        buf[0] = argv[cur++];
        SPutField(dst, pre, buf, 1, width, left, FALSE);
        break;
      case 's':
        s = argv[cur++];
        if (!s)
          s = "(null)";
        len = 0;
        while (s[len] && (prec < 0 || len < prec))
          len++;
        SPutField(dst, pre, s, len, width, left, FALSE);
        break;
      case 'f':
        fv = *(&argv[cur])(F64 *);   // slot holds the raw F64 bits
        cur++;
        if (prec < 0)
          prec = 6;
        if (fv < 0) {
          pre[0] = '-';
          pre[1] = 0;
          fv = -fv;
        }
        // Simple fixed point (integer part < 2^63): round, then emit digits.
        frac = 0.5;
        for (i = 0; i < prec; i++)
          frac = frac / 10.0;
        fv = fv + frac;
        v = fv;   // implicit truncating conversion
        p = SUtoA(end, v, 10, FALSE);
        len = end - p;
        i = width;   // reserve room for the fraction
        if (prec)
          i -= prec + 1;
        SPutField(dst, pre, p, len, i, left, zero);
        if (prec) {
          SPutCh(dst, '.');
          i = v;
          fv = fv - i;
          for (i = 0; i < prec; i++) {
            fv = fv * 10.0;
            ch = fv;
            SPutCh(dst, '0' + ch);
            fv = fv - ch;
          }
        }
        break;
      case 'd':
      case 'i':
        sgn = TRUE;
        goto num;
      case 'X':
        upper = TRUE;
      case 'x':
        radix = 16;
        goto num;
      case 'o':
        radix = 8;
        goto num;
      case 'b':
        radix = 2;
        goto num;
      case 'u':
        goto num;
      case 'p':
        radix = 16;
        upper = TRUE;
        pre[0] = '0';
        pre[1] = 'x';
        pre[2] = 0;
        if (!width) {
          width = 18;
          zero = TRUE;
        }
num:
        v = argv[cur++];
        if (sgn && v(I64) < 0) {
          pre[0] = '-';
          pre[1] = 0;
          v = -v(I64);   // I64 min wraps to 2^63, correct as U64
        }
        p = SUtoA(end, v, radix, upper);
        len = end - p;
        if (prec >= 0) {   // minimum digits
          zero = FALSE;
          while (len < prec && p > buf) {
            *--p = '0';
            len++;
          }
        }
        SPutField(dst, pre, p, len, width, left, zero);
        break;
      default:   // unknown: echo it
        SPutCh(dst, '%');
        SPutCh(dst, ch);
    }
next:
  }
  if (dst)
    **dst = 0;
}

// Format into dst (caller guarantees space); returns dst.
U8 *StrPrint(U8 *dst, U8 *fmt, ...)
{
  U8 *d = dst;
  KFmt(&d, fmt, argc, argv);
  return dst;
}

// Print to the UART. Bare string statements ("fmt", args;) compile to this.
I64 print_lock;

U0 Print(U8 *fmt, ...)
{//One core prints at a time so lines don't interleave.
  I64 daif=SpinLockIrq(&print_lock);
  KFmt(NULL, fmt, argc, argv);
  SpinUnlockIrq(&print_lock,daif);
}
