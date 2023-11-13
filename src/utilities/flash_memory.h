#ifndef FLASH_MEMORY_H
#define FLASH_MEMORY_H

// #include <stdarg.h>

enum flash_memory_sector_size
{
    flash_memory_sector_size_4k,
    flash_memory_sector_size_32k,
    flash_memory_sector_size_64k,
    flash_memory_sector_size_256k
};

// enum flash_memory_page_size
// {
//     flash_memory_page_size_256,
//     flash_memory_page_size_512
// };

// #define FLASH_MEMORY_NO_ERROR 0

// typedef struct {
//     unsigned long size;
//     flash_memory_sector_size min_uniform_sector_size;
//     flash_memory_page_size page_size;
// } flash_memory_descriptor;

struct flash_memory_interface {
    // size_t size;
    // void * (*ctor) (void * self, va_list * app);
    // void * (*dtor) (void * self);
    // int (*probe) (void * self, flash_memory_descriptor *descriptor);
    int (*probe) (void * self);
    int (*reset) (void * self);
    int (*erase_sector) (void * self, enum flash_memory_sector_size sector_size, unsigned long address);
    // int (*program_page) (void * self, flash_memory_page_size page_size, const char *data);
};

// void * flash_memory_new(const void * flash_memory_type, ...);
// void flash_memory_delete(void * self);
int flash_memory_probe(void * self);
int flash_memory_reset(void * self);
int flash_memory_erase_sector(void * self, enum flash_memory_sector_size sector_size, unsigned long address);

#endif
