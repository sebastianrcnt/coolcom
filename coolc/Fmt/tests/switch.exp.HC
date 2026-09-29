U0 F(I64 ch)
{
  switch (ch) {
    case 0:
    case 1:
      x=1;
      break;
    case 'a':
      if (x)
        y=2;
      z=3;
      break;
    case 'b': {
        w=1;
      }
      break;
    default:   // unknown
      x=2;
  }
  switch (ch) {
    default:
      if (a) goto next;
      x=1;
next:
      y=2;
  }
  goto done;
done:
  return;
}
