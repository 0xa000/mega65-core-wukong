#include <hal.h>
#include <memory.h>
#include <stdio.h>

#include "flash_memory.h"
#include "qspicommon.h"

struct s25flxxxl {
    // const struct flash_memory_interface * interface;
    const struct flash_memory_interface interface;
    // attributes
    unsigned char reg_sr1;
    unsigned char reg_sr2;
};

static int s25flxxxl_reset(void * self) {
//    struct s25flxxxl * _self = self;
    (void) self;

    spi_cs_high();
    usleep(10000);

    // Allow lots of clock ticks to get attention of SPI
    spi_idle_clocks(256);

    spi_clock_high();
    delay();
    spi_cs_low();
    delay();

    spi_tx_byte(0x66); // Reset enable.
    spi_cs_high();
    delay();
    spi_clock_high();
    delay();
    spi_cs_low();
    delay();
    spi_tx_byte(0x99); // Reset.
    spi_cs_high();
    usleep(10000);

    return 0;
}

static int s25flxxxl_erase_sector(void * self, enum flash_memory_sector_size sector_size, unsigned long address) {

    struct s25flxxxl * _self = self;

    while ((_self->reg_sr1 & 0x01) || (_self->reg_sr2 & 0x60)) {
        spi_cs_high();
        spi_clock_high();
        delay();
        spi_cs_low();
        delay();
        spi_tx_byte(0x30);
        spi_cs_high();
        read_registers();
    }

    spi_write_enable();

    spi_cs_high();
    spi_clock_high();
    delay();
    spi_cs_low();
    delay();
    // if ((address >> 12) >= num_4k_sectors) {
    if ((address >> 12) >= 16) {
        // Do 64KB/256KB sector erase
        printf("erasing large sector.\n");
        POKE(0xD681, address >> 0);
        POKE(0xD682, address >> 8);
        POKE(0xD683, address >> 16);
        POKE(0xD684, address >> 24);
        // Erase large page
        POKE(0xd680, 0x58);
    }
    else {
        // Do fast 4KB sector erase
        printf("erasing small sector.\n");
        spi_tx_byte(0x21);
        spi_tx_byte(address >> 24);
        spi_tx_byte(address >> 16);
        spi_tx_byte(address >> 8);
        spi_tx_byte(address >> 0);
        spi_clock_low();
        spi_cs_high();
        delay();
    }

    return 0;
}

// static const struct flash_memory_interface _s25flxxxl = {
//     sizeof(struct s25flxxxl), 0, 0, s25flxxxl_reset
// };

// const void * s25flxxxl = & _s25flxxxl;

static struct s25flxxxl _s25flxxxl = {
    {0, s25flxxxl_reset, s25flxxxl_erase_sector}
};

void * s25flxxxl = & _s25flxxxl;
