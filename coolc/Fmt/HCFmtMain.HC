// Driver for HCFmt.HC (include HCFmt.HC first). Plain file/string calls only.
//   HCFmtFile(name,mode) formats one file:
//     HCF_WRITE  rewrite the file if it changes
//     HCF_CHECK  only report, never write
//     HCF_TOFMT  write the result to name.fmt (for diffing), even if unchanged
//   Returns 0 unchanged, 1 changed, 2 error (unreadable or token check failed).
//   One line "HCFMT <status> <name>" is printed per file.

#define HCF_WRITE 0
#define HCF_CHECK 1
#define HCF_TOFMT 2

U0 HCFmtWriteExt(U8 *name,U8 *ext,U8 *buf)
{
  U8 *fname=MAlloc(StrLen(name)+StrLen(ext)+1);
  StrCpy(fname,name);
  StrCpy(fname+StrLen(name),ext);
  FileWrite(fname,buf,StrLen(buf));
  Free(fname);
}

I64 HCFmtFile(U8 *name,I64 mode)
{
  U8 *src,*out,*again;
  I64 size=0,changed=0,ret=0;
  src=FileRead(name,&size);
  if (!src) {
    "HCFMT ERROR-READ %s\n",name;
    return 2;
  }
  out=HCFmt(src);
  if (hcfmt_err) {
    "HCFMT ERROR-TOKENS %s\n",name;
    ret=2;
  } else {
    if (StrCmp(src,out))
      changed=1;
    if (hcfmt_warn)
      "HCFMT WARN-UNBALANCED %s\n",name;
    again=HCFmt(out);
    if (StrCmp(out,again))
      "HCFMT WARN-NOT-IDEMPOTENT %s\n",name;
    Free(again);
    if (mode==HCF_TOFMT)
      HCFmtWriteExt(name,".fmt",out);
    else if (mode==HCF_WRITE && changed)
      FileWrite(name,out,StrLen(out));
    if (changed) {
      "HCFMT CHANGED %s\n",name;
      ret=1;
    } else
      "HCFMT OK %s\n",name;
  }
  Free(src);
  Free(out);
  return ret;
}

// One test: format inp and compare with the expected file exp, which must
// also be a fixed point. On failure the actual output goes to inp.got.
// Returns TRUE on pass.
Bool HCFmtTest(U8 *inp,U8 *exp)
{
  U8 *a,*b,*o,*o2;
  I64 sz=0;
  Bool ok=TRUE;
  a=FileRead(inp,&sz);
  b=FileRead(exp,&sz);
  if (!a || !b) {
    "HCFMT-TEST FAIL %s (cannot read)\n",inp;
    return FALSE;
  }
  o=HCFmt(a);
  if (hcfmt_err) {
    "HCFMT-TEST FAIL %s (token check)\n",inp;
    ok=FALSE;
  }
  if (StrCmp(o,b)) {
    "HCFMT-TEST FAIL %s (output differs from expected)\n",inp;
    HCFmtWriteExt(inp,".got",o);
    ok=FALSE;
  }
  o2=HCFmt(b);
  if (StrCmp(o2,b)) {
    "HCFMT-TEST FAIL %s (expected is not a fixed point)\n",exp;
    ok=FALSE;
  }
  if (ok)
    "HCFMT-TEST PASS %s\n",inp;
  Free(a);
  Free(b);
  Free(o);
  Free(o2);
  return ok;
}
