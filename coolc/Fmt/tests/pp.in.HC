#define   FOO   (1+2)
#define BAR(x)  x  *  2
#include   "x.HC"
   #ifdef   FOO
U0 F()
{
  a=FOO+1;
      #ifdef A
  a  =  1;
      #endif
#define   LOCAL  a-b
#exe {StreamPrint("#define A %d",1);  x = y;};
  b=2;
}
#endif
#ifndef X
#define X 1
#endif
