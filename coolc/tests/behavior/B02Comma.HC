I64 CommaValue() { return 1, 2; }
I64 CommaSideEffect()
{
  I64 a = 0;
  return (a = 7), (a + 3);
}

Print("%d %d\n", CommaValue(), CommaSideEffect());
