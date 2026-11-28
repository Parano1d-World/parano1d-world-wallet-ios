#ifndef PARANOID_NODE_H
#define PARANOID_NODE_H
#include <stdint.h>
#include <stddef.h>
char *paranoid_node_call(const uint8_t *input, size_t length);
void paranoid_node_free(char *value);
#endif
