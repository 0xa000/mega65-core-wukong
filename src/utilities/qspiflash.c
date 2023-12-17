#include <stddef.h>

#include "qspiflash.h"
#include "s25flxxxl.h"
#include "s25flxxxs.h"

char qspi_flash_probe(void * self, struct qspi_flash_descriptor * descriptor) {
    const struct qspi_flash_interface * interface = self;
    if (interface == NULL || interface->probe == NULL)
        return -1;
    return interface->probe(self, descriptor);
}

char qspi_flash_reset(void * self) {
    const struct qspi_flash_interface * interface = self;
    if (interface == NULL || interface->reset == NULL)
        return -1;
    return interface->reset(self);
}

char qspi_flash_read(void * self, unsigned long address, unsigned char * data, unsigned int size) {
    const struct qspi_flash_interface * interface = self;
    if (interface == NULL || interface->read == NULL)
        return -1;
    return interface->read(self, address, data, size);
}

char qspi_flash_verify(void * self, unsigned long address, unsigned char * data, unsigned int size) {
    const struct qspi_flash_interface * interface = self;
    if (interface == NULL || interface->verify == NULL)
        return -1;
    return interface->verify(self, address, data, size);
}

char qspi_flash_erase_sector(void * self, enum qspi_flash_sector_size sector_size, unsigned long address) {
    const struct qspi_flash_interface * interface = self;
    if (interface == NULL || interface->erase_sector == NULL)
        return -1;
    return interface->erase_sector(self, sector_size, address);
}

char qspi_flash_program_page(void * self, unsigned long address, const unsigned char * data) {
    const struct qspi_flash_interface * interface = self;
    if (interface == NULL || interface->program_page == NULL)
        return -1;
    return interface->program_page(self, address, data);
}
