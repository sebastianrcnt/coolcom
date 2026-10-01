/* Keep upstream lua.c unchanged; customize only its supported readline hook. */
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include "lua.h"

static int coolcom_readline(lua_State *L, char *buffer, const char *prompt,
                            int firstline, int capacity) {
  const char *start, *end;
  int undefined;
  fputs(prompt, stdout);
  fflush(stdout);
  if (fgets(buffer, capacity, stdin) == NULL)
    return 0;
  start = buffer;
  while (isspace((unsigned char)*start)) start++;
  end = start + strlen(start);
  while (end > start && isspace((unsigned char)end[-1])) end--;
  if (firstline && end - start == 4 && strncmp(start, "exit", 4) == 0) {
    undefined = lua_getglobal(L, "exit") == LUA_TNIL;
    lua_pop(L, 1);
    if (undefined) return 0;  /* `exit` leaves like Ctrl+D (unless a script defined it) */
  }
  return 1;
}

#define lua_readline(L,b,p) coolcom_readline(L,b,p,firstline,LUA_MAXINPUT)
#define lua_initreadline(L) ((void)L)
#define lua_saveline(L,line) { (void)L; (void)line; }
#define lua_freeline(L,b) { (void)L; (void)b; }
#include "lua.c"
