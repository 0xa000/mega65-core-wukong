#ifndef QSPIFLASH_H
#define QSPIFLASH_H

typedef enum { FALSE, TRUE } BOOL;

// #define QSPI_FLASH_SUCCESS (0)
// #define QSPI_FLASH_ERROR   (-1)

enum qspi_flash_sector_size
{
    qspi_flash_sector_size_4k,
    qspi_flash_sector_size_32k,
    qspi_flash_sector_size_64k,
    qspi_flash_sector_size_256k,

    /* This entry should always be last. */
    qspi_flash_sector_size_last
};

enum qspi_flash_page_size
{
    qspi_flash_page_size_256,
    qspi_flash_page_size_512
};

struct qspi_flash_descriptor
{
    const char * manufacturer;
    unsigned char memory_size_mb;
    BOOL uniform_sector_sizes[qspi_flash_sector_size_last];
    enum qspi_flash_page_size page_size;
    unsigned char read_latency_cycles;
    BOOL quad_mode_enabled;
    BOOL memory_array_protection_enabled;
    BOOL register_protection_enabled;
};

struct qspi_flash_interface
{
    char (*reset) (void * self);
    char (*probe) (void * self, struct qspi_flash_descriptor * descriptor);
    char (*read) (void * self, unsigned long address, unsigned char * data, unsigned int size);
    char (*verify) (void * self, unsigned long address, unsigned char * data, unsigned int size);
    char (*erase_sector) (void * self, enum qspi_flash_sector_size sector_size, unsigned long address);
    char (*program_page) (void * self, unsigned long address, const unsigned char * data);
};

char qspi_flash_reset(void * self);
char qspi_flash_probe(void * self, struct qspi_flash_descriptor * descriptor);
char qspi_flash_read(void * self, unsigned long address, unsigned char * data, unsigned int size);
char qspi_flash_verify(void * self, unsigned long address, unsigned char * data, unsigned int size);
char qspi_flash_erase_sector(void * self, enum qspi_flash_sector_size sector_size, unsigned long address);
char qspi_flash_program_page(void * self, unsigned long address, const unsigned char * data);

#endif /* QSPIFLASH_H */
