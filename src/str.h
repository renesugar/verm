#ifndef _STR_H
#define _STR_H

#include <unistd.h>

int strendswith(const char *str, const char *ending);
long atoi_or_default(const char* s, long def);
int boolean(const char *data, size_t size);
const char *strr2ndchr(const char *s, int c);

#endif
