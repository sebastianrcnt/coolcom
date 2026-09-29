// Kernel entry: everything AOT-compiled into the kernel image is included from here.
#include "KernelA.HH"
#include "Uart.HC"
#include "StrPrint.HC"

U0 KMain()
{
  U8 sb[64];
  UartPutS("hi from HolyC\n");
  "Hello %d %s %X\n", 42, "abc", 0xBEEF;
  Print("x=%08X|%8x|%-8x|\n", 0xBEEF, 0xBEEF, 0xBEEF);
  "d: %d %d %d %d\n", 0, -1, I64_MAX, I64_MIN;
  "u: %u %u %X\n", 0, -1, -1;
  "w: [%2d] [%5d] [%-5d] [%05d] [%05d]\n", 123456, -42, -42, 42, -42;
  "s: [%s] [%5s] [%-5s] [%2s] [%.2s]\n", "", "ab", "ab", "abcdef", "abcdef";
  "c: %c%c%c %% %p\n", 'H', 'i', '!', 0xDEAD;
  "p: %p %10p\n", 0x40081000, 0;
  "*: [%*d] [%-*d]\n", 6, 7, 6, 7;
  "b/o: %b %o\n", 10, 64;
  "f: %f %.2f %8.3f %.0f %f\n", 3.14159, -2.5, 1.0005, 2.5, 0.0;
  "plain string no args\n";
  StrPrint(sb, "%s-%d", "buf", 99);
  "sp: %s\n", sb;
  while (TRUE) {}
}
