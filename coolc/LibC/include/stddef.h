#ifndef _LC_STDDEF_H
#define _LC_STDDEF_H
typedef unsigned long size_t;
typedef long ptrdiff_t;
typedef int wchar_t;
typedef long intptr_t;
typedef unsigned long uintptr_t;
#define NULL ((void *)0)
#define offsetof(t, m) ((size_t)&(((t *)0)->m))
#endif
