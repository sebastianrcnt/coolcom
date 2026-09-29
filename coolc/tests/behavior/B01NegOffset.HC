U8 neg_bytes[6008];
I64 neg_words[600];

I64 NegReadByte(U8 *p) { return p[-3000]; }
I64 NegReadWord(I64 *p) { return p[-300]; }
U0 NegWriteByte(U8 *p) { p[-3000] = 42; }
U0 NegWriteWord(I64 *p) { p[-300] = 74; }

neg_bytes[0] = 41;
neg_words[0] = 73;
Print("before %d %d\n", neg_bytes[0], neg_words[0]);
Print("read %d %d\n", NegReadByte(&neg_bytes[3000]), NegReadWord(&neg_words[300]));
NegWriteByte(&neg_bytes[3000]);
NegWriteWord(&neg_words[300]);
Print("after %d %d\n", neg_bytes[0], neg_words[0]);
