#include <stddef.h>

#include "flash_memory.h"
#include "s25flxxxl.h"
#include "s25flxxxs.h"

char flash_memory_probe(void * self, struct flash_memory_descriptor * descriptor) {
    const struct flash_memory_interface * interface = self;
    if (interface == NULL || interface->probe == NULL)
        return -1;
    return interface->probe(self, descriptor);
}

char flash_memory_reset(void * self) {
    const struct flash_memory_interface * interface = self;
    if (interface == NULL || interface->reset == NULL)
        return -1;
    return interface->reset(self);
}

char flash_memory_read(void * self, unsigned long address, unsigned char * data) {
    const struct flash_memory_interface * interface = self;
    if (interface == NULL || interface->read == NULL)
        return -1;
    return interface->read(self, address, data);
}

char flash_memory_erase_sector(void * self, enum flash_memory_sector_size sector_size, unsigned long address) {
    const struct flash_memory_interface * interface = self;
    if (interface == NULL || interface->erase_sector == NULL)
        return -1;
    return interface->erase_sector(self, sector_size, address);
}

char flash_memory_program_page(void * self, unsigned long address, const unsigned char * data) {
    const struct flash_memory_interface * interface = self;
    if (interface == NULL || interface->program_page == NULL)
        return -1;
    return interface->program_page(self, address, data);
}
