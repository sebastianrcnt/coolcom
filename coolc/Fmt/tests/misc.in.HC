U8 *s="a   
  b  
";   
U0 F()
{
x = "q";  
/* c1   
  c2  */   
if (x) {
#ifdef FOO
y();
#endif
}
#exe {StreamPrint("#define A %d",1);};
z();
}
