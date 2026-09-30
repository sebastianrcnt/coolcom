#ifndef _LC_STDIO_H
#define _LC_STDIO_H
#include <stddef.h>
#include <stdarg.h>
typedef struct LC_FILE FILE;
#define EOF (-1)
#define BUFSIZ 8192
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2
#define FILENAME_MAX 1024
#define L_tmpnam 32
#define TMP_MAX 1000
extern FILE *stdin, *stdout, *stderr;
FILE *fopen(const char *name, const char *mode);
FILE *freopen(const char *name, const char *mode, FILE *f);
FILE *tmpfile(void);
int fclose(FILE *f);
int fflush(FILE *f);
size_t fread(void *p, size_t size, size_t count, FILE *f);
size_t fwrite(const void *p, size_t size, size_t count, FILE *f);
int fgetc(FILE *f);
int getc(FILE *f);
int getchar(void);
int ungetc(int c, FILE *f);
int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int putchar(int c);
int fputs(const char *s, FILE *f);
int puts(const char *s);
char *fgets(char *s, int n, FILE *f);
int feof(FILE *f);
int ferror(FILE *f);
void clearerr(FILE *f);
int fseek(FILE *f, long off, int whence);
long ftell(FILE *f);
void rewind(FILE *f);
int setvbuf(FILE *f, char *buf, int mode, size_t size);
void setbuf(FILE *f, char *buf);
int fileno(FILE *f);
int printf(const char *format, ...);
int fprintf(FILE *f, const char *format, ...);
int sprintf(char *dst, const char *format, ...);
int snprintf(char *dst, size_t size, const char *format, ...);
int vprintf(const char *format, va_list ap);
int vfprintf(FILE *f, const char *format, va_list ap);
int vsprintf(char *dst, const char *format, va_list ap);
int vsnprintf(char *dst, size_t size, const char *format, va_list ap);
int remove(const char *name);
int rename(const char *from, const char *to);
char *tmpnam(char *buf);
#endif
