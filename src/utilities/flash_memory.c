// #include <stdlib.h>
#include <assert.h>
#include <stdio.h>

#include "flash_memory.h"
#include "s25flxxxl.h"
#include "s25flxxxs.h"

// void * flash_memory_new(const void * flash_memory_type, ...)
// {
//     const struct flash_memory_interface * interface = flash_memory_type;
//     void * object = calloc(1, interface->size);
//     assert(object);

//     * (const struct flash_memory_interface **) object = interface;

//     if (interface->ctor)
//     {
//         va_list args;
//         va_start(args, flash_memory_type);
//         object = interface->ctor(object, &args);
//         va_end(args);
//     }

//     return object;
// }

// void flash_memory_delete(void * self)
// {
//     const struct flash_memory_interface ** interface = self;
//     if (self && *interface && (*interface)->dtor)
//         self = (*interface)->dtor(self);
//     free(self);
// }

int flash_memory_probe(void * self) {
    const struct flash_memory_interface * interface = self;
    assert(interface);
    if (interface->probe)
        interface->probe(self);
    return 0;
}

int flash_memory_reset(void * self) {
    const struct flash_memory_interface * interface = self;
    if (interface->reset)
        interface->reset(self);
    return 0;
}

int flash_memory_erase_sector(void * self, enum flash_memory_sector_size sector_size, unsigned long address) {
    const struct flash_memory_interface * interface = self;
    if (interface->erase_sector)
        interface->erase_sector(self, sector_size, address);
    return 0;
}
