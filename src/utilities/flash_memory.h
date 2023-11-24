#ifndef FLASH_MEMORY_H
#define FLASH_MEMORY_H

typedef enum { FALSE, TRUE } BOOL;

// #define FLASH_MEMORY_SUCCESS (0)
// #define FLASH_MEMORY_ERROR   (-1)

enum flash_memory_sector_size
{
    flash_memory_sector_size_4k,
    flash_memory_sector_size_32k,
    flash_memory_sector_size_64k,
    flash_memory_sector_size_256k,

    /* This entry should always be last. */
    flash_memory_sector_size_last
};

enum flash_memory_page_size
{
    flash_memory_page_size_256,
    flash_memory_page_size_512
};

struct flash_memory_descriptor {
    const char * manufacturer;
    unsigned short memory_size_mb;
    BOOL uniform_sector_sizes[flash_memory_sector_size_last];
    enum flash_memory_page_size page_size;
    unsigned char read_latency_cycles;
    BOOL quad_mode_enabled;
    BOOL memory_array_protection_enabled;
    BOOL register_protection_enabled;
};

struct flash_memory_interface {
    char (*reset) (void * self);
    char (*probe) (void * self, struct flash_memory_descriptor * descriptor);
    char (*read) (void * self, unsigned long address, unsigned char * data);
    char (*erase_sector) (void * self, enum flash_memory_sector_size sector_size, unsigned long address);
    char (*program_page) (void * self, unsigned long address, const unsigned char * data);
};

char flash_memory_reset(void * self);
char flash_memory_probe(void * self, struct flash_memory_descriptor * descriptor);
char flash_memory_read(void * self, unsigned long address, unsigned char * data);
char flash_memory_erase_sector(void * self, enum flash_memory_sector_size sector_size, unsigned long address);
char flash_memory_program_page(void * self, unsigned long address, const unsigned char * data);

#endif
