U0 F()
{
  U8 *s="brace { in string";
  U8 *t="quote \" and } here // not comment";
  I64 c='{',d='\'',e='AB',f='\\';
  "multi
   line { string
";
  /* block { comment
       } still comment   */
  x=1; /* inline } */ y=2;
  // { comment
  if (x)
    z="}";
}
#define BRACE '{'
#define STR "}"
U0 G()
{
  x=1;
}
