#include <stdio.h>

#include "flash_memory.h"

struct s25flxxxs {
    const struct flash_memory_interface interface;
    // attributes
};

static char s25flxxxs_reset(void * self)
{
    (void) self;
    return 0;
}

static struct s25flxxxs _s25flxxxs = {
    {s25flxxxs_reset, NULL, NULL, NULL, NULL}
};

void * s25flxxxs = & _s25flxxxs;
