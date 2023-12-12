#include <hal.h>
#include <memory.h>
#include <stdio.h>

#include "flash_memory.h"
#include "qspihwassist.h"
#include "qspibitbash.h"

static unsigned char read_status_register_1(void)
{
    return spi_transaction_tx8rx8(0x05);
}

static unsigned char read_status_register_2(void)
{
    return spi_transaction_tx8rx8(0x07);
}

static unsigned char read_configuration_register_1(void)
{
    return spi_transaction_tx8rx8(0x35);
}

static void write_enable(void)
{
    spi_transaction_tx8(0x06);
}

static void clear_status_register(void)
{
    spi_transaction_tx8(0x30);
}

struct s25flxxxs_status
{
    unsigned char sr1;
    unsigned char sr2;
};

static struct s25flxxxs_status read_status(void)
{
    struct s25flxxxs_status status;
    status.sr1 = read_status_register_1();
    status.sr2 = read_status_register_2();
    return status;
}

static BOOL erase_error_occurred(const struct s25flxxxs_status * status)
{
    return (status->sr1 & 0x20 ? TRUE : FALSE);
}

static BOOL program_error_occurred(const struct s25flxxxs_status * status)
{
    return (status->sr1 & 0x40 ? TRUE : FALSE);
}

static BOOL write_enabled(const struct s25flxxxs_status * status)
{
    return (status->sr1 & 0x02 ? TRUE : FALSE);
}

static BOOL write_in_progress(const struct s25flxxxs_status * status)
{
    return (status->sr1 & 0x01 ? TRUE : FALSE);
}

static BOOL busy(const struct s25flxxxs_status * status)
{
    return (status->sr1 & 0x03 ? TRUE : FALSE);
}

static BOOL error_occurred(const struct s25flxxxs_status * status)
{
    return (status->sr1 & 0x60 ? TRUE : FALSE);
}

static void clear_status(void)
{
    struct s25flxxxs_status status;
    for (;;)
    {
        status = read_status();
        if (!busy(&status) && !error_occurred(&status))
            break;
        clear_status_register();
    }
}

static char wait_status(void)
{
    struct s25flxxxs_status status;
    for (;;)
    {
        status = read_status();
        if (!busy(&status))
            break;
    }
    return (error_occurred(&status) ? -1 : 0);
}

static char enable_quad_mode(void)
{
    unsigned char spi_tx[] = {0x01, 0x00, 0x00};

    spi_tx[1] = read_status_register_1();
    spi_tx[2] = read_configuration_register_1();
    spi_tx[2] |= 0x02;

    write_enable();
    spi_transaction(spi_tx, 3, NULL, 0);
    return wait_status();
}

struct s25flxxxs
{
    // Interface.
    const struct flash_memory_interface interface;
    // Attributes.
    BOOL uniform_256K_sectors;
    BOOL sectors_4k_at_top;
    BOOL page_size_512;
    unsigned short num_64k_sectors;
    unsigned char read_latency_cycles;
};

static char s25flxxxs_reset(void * self)
{
    (void) self;

    spi_cs_high();
    spi_clock_high();

    usleep(10000);

    // Allow lots of clock ticks to get attention of SPI
    spi_idle_clocks(255);

    // Reset.
    spi_transaction_tx8(0xf0);

    usleep(10000);
    return 0;
}

static char s25flxxxs_probe(void * self, struct flash_memory_descriptor * descriptor)
{
    const uint8_t spi_tx[] = {0x9f};
    uint8_t spi_rx[44] = {0x00};
    unsigned char cr1;
    BOOL quad_mode_enabled;
    struct s25flxxxs * self_ = (struct s25flxxxs *) self;

    if (s25flxxxs_reset(self) != 0)
        return -1;

    // Read RDID to confirm model and get density.
    spi_transaction(spi_tx, 1, spi_rx, 44);
    if (spi_rx[0] != 0x01)
        return -1;

    descriptor->manufacturer = "Infineon";
    if (spi_rx[1] == 0x20 && spi_rx[2] == 0x18)
    {
        // 128 Mb
        descriptor->memory_size_mb = 16;
        self_->num_64k_sectors = 256;
    }
    else if (spi_rx[1] == 0x02 && spi_rx[2] == 0x19)
    {
        // 256 Mb
        descriptor->memory_size_mb = 32;
        self_->num_64k_sectors = 512;
    }
    else if (spi_rx[1] == 0x02 && spi_rx[2] == 0x20)
    {
        // 256 Mb
        descriptor->memory_size_mb = 64;
        self_->num_64k_sectors = 1024;
    }
    else
    {
        return -1;
    }

    if (spi_rx[3] != 0x4d)
    {
        return -1;
    }

    if (spi_rx[4] == 0x00)
    {
        // Uniform 256K sectors.
        self_->uniform_256K_sectors = TRUE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_4k  ] = FALSE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_32k ] = FALSE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_64k ] = FALSE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_256k] = TRUE;
    }
    else if (spi_rx[4] == 0x01)
    {
        // Mixed 4K / 64K sectors.
        self_->uniform_256K_sectors = FALSE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_4k  ] = FALSE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_32k ] = FALSE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_64k ] = TRUE;
        descriptor->uniform_sector_sizes[flash_memory_sector_size_256k] = FALSE;
    }
    else
    {
        return -1;
    }

    cr1 = read_configuration_register_1();
    self_->read_latency_cycles = ((cr1 >> 6) == 3) ? 0 : 8;
    self_->sectors_4k_at_top = (cr1 & 0x04) ? TRUE : FALSE;

    // Determine page size.
    if (spi_rx[42] == 0x08)
    {
        // Page size 256 bytes.
        descriptor->page_size = flash_memory_page_size_256;
        self_->page_size_512 = FALSE;
    }
    else if (spi_rx[42] == 0x09)
    {
        // Page size 512 bytes.
        descriptor->page_size = flash_memory_page_size_512;
        self_->page_size_512 = TRUE;
    }
    else
    {
        return -1;
    }

    // Enable quad mode if it is not enabled, and verify.
    quad_mode_enabled = cr1 & 0x02;
    if (!quad_mode_enabled)
    {
        if (enable_quad_mode() != 0)
        {
           return -1;
        }
        cr1 = read_configuration_register_1();
        quad_mode_enabled = cr1 & 0x02;
    }

    if (!quad_mode_enabled)
    {
        return -1;
    }

    // TODO: Find out if registers or memory array is write protected.
    descriptor->read_latency_cycles = self_->read_latency_cycles;
    descriptor->quad_mode_enabled = quad_mode_enabled;
    descriptor->memory_array_protection_enabled = FALSE;
    descriptor->register_protection_enabled = FALSE;

    return 0;
}

static char s25flxxxs_read(void * self, unsigned long address, unsigned char * data)
{
    unsigned short i;
    const struct s25flxxxs * self_ = (const struct s25flxxxs *) self;
    clear_status();
    spi_clock_high();
    spi_cs_low();
    spi_output_enable();
    spi_tx_byte(0x6c);
    spi_tx_byte(address >> 24);
    spi_tx_byte(address >> 16);
    spi_tx_byte(address >> 8);
    spi_tx_byte(address >> 0);
    spi_output_disable();
    spi_idle_clocks(self_->read_latency_cycles);
    if (data == NULL)
    {
        for (i = 0; i < 512; ++i)
        {
            qspi_rx_byte();
        }
    }
    else
    {
        for (i = 0; i < 512; ++i)
        {
            data[i] = qspi_rx_byte();
        }
    }
    spi_cs_high();
    spi_clock_high();
    return 0;
}

static char erase_4k_parameter_sector(unsigned long address)
{
    unsigned char spi_tx[5];

    spi_tx[0] = 0x21;
    spi_tx[1] = address >> 24;
    spi_tx[2] = address >> 16;
    spi_tx[3] = address >> 8;
    spi_tx[4] = address >> 0;

    clear_status();
    write_enable();
    spi_transaction(spi_tx, 5, NULL, 0);

    return wait_status();
}

static char erase_sector(unsigned long address)
{
    unsigned char spi_tx[5];

    spi_tx[0] = 0xdc;
    spi_tx[1] = address >> 24;
    spi_tx[2] = address >> 16;
    spi_tx[3] = address >> 8;
    spi_tx[4] = address >> 0;

    clear_status();
    write_enable();
    spi_transaction(spi_tx, 5, NULL, 0);

    return wait_status();
}

static char s25flxxxs_erase_sector(void * self, enum flash_memory_sector_size sector_size, unsigned long address)
{
    const struct s25flxxxs * self_ = (const struct s25flxxxs *) self;

    if (self_->uniform_256K_sectors)
    {
        if (sector_size != flash_memory_sector_size_256k)
        {
            return -1;
        }

        return erase_sector(address);
    }
    else
    {
        unsigned short sector_number_64k;

        if (sector_size != flash_memory_sector_size_64k)
        {
            return -1;
        }

        sector_number_64k = address >> 16;

        if ((self_->sectors_4k_at_top && (sector_number_64k >= self_->num_64k_sectors - 2)) || (sector_number_64k < 2))
        {
            unsigned char i;

            address &= ~0xffffUL;

            for (i = 0; i < 16; ++i)
            {
                char result;

                result = erase_4k_parameter_sector(address);
                if (result != 0)
                {
                    return result;
                }

                address += 4096;
            }
        }
        else
        {
            return erase_sector(address);
        }
    }
}

static char s25flxxxs_program_page(void * self, unsigned long address, const unsigned char * data)
{
    unsigned short i = 0;
    const struct s25flxxxs * self_ = (const struct s25flxxxs *) self;

    if ((address & 0xff) || (self_->page_size_512 && (address & 0x1ff)))
    {
        // Address not aligned to page boundary.
        return -1;
    }

    clear_status();
    write_enable();
    spi_clock_high();
    spi_cs_low();
    spi_output_enable();
    spi_tx_byte(0x34);
    spi_tx_byte(address >> 24);
    spi_tx_byte(address >> 16);
    spi_tx_byte(address >> 8);
    spi_tx_byte(address >> 0);

    for (i = 0; i <= 256; ++i)
    {
        qspi_tx_byte(data[i]);
    }

    if (self_->page_size_512)
    {
        for (i = 0; i < 256; ++i)
        {
            qspi_tx_byte(data[i]);
        }
    }

    spi_output_disable();
    spi_cs_high();
    spi_clock_high();

    return wait_status();
}

static struct s25flxxxs _s25flxxxs = {
    {s25flxxxs_reset, s25flxxxs_probe, s25flxxxs_read, s25flxxxs_erase_sector, s25flxxxs_program_page}
};

void * s25flxxxs = & _s25flxxxs;
