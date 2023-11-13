#include <stdio.h>

#include "flash_memory.h"

struct s25flxxxs {
    // const struct flash_memory_interface * interface;
    const struct flash_memory_interface interface;
    // attributes
};

static int s25flxxxs_reset(void * self)
{
//    struct s25flxxxs * _self = self;
    (void) self;
    return 0;
}

// static const struct flash_memory_interface _s25flxxxs = {
//     sizeof(struct s25flxxxs), 0, 0, s25flxxxs_reset
// };

// const void * s25flxxxs = & _s25flxxxs;

static struct s25flxxxs _s25flxxxs = {
    {0, s25flxxxs_reset, 0}
};

void * s25flxxxs = & _s25flxxxs;
