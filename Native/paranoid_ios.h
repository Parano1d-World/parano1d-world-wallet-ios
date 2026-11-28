#ifndef PARANOID_IOS_H
#define PARANOID_IOS_H
#include <stdint.h>
#include <stddef.h>
char *paranoid_ios_call(const uint8_t *input, size_t length, const uint8_t *secret, size_t secret_length);
void paranoid_ios_free(char *value);
#endif
