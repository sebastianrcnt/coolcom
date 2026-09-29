U0 F()
{
    x = 1;
    asm {
        MOV   RAX,   [RBX+8]
        ADD RAX ,1 // note
        JMP   @@1
    @@1:   NOP
    LAB2::
    }
    y = 2;
}
asm
{
SYM::
    MOV X0,  #1
}
U0 G() {asm {NOP}
    z = 3;
}
