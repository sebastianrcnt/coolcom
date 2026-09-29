U0 F()
{
  asm {
    MOV RAX,1
  @@05: ADD RAX,2
    JNE @@05
  LAB::
    RET
  }
  x=1;
}
asm {
SYM::
  NOP
}
U0 G()
{
  x=1;
}
