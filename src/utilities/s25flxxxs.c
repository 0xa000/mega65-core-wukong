#include <hal.h>
#include <memory.h>
#include <stdio.h>

#include "qspiflash.h"
#include "qspihwassist.h"
#include "qspibitbash.h"

#ifdef QSPI_VERBOSE
#include "mhexes.h"
#endif

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

static void write_disable(void)
{
    spi_transaction_tx8(0x04);
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

    // Clear write enable latch (WEL).
    write_disable();
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

    clear_status();
    write_enable();
    spi_transaction(spi_tx, 3, NULL, 0);

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

struct s25flxxxs
{
    // Interface.
    const struct qspi_flash_interface interface;
    // Attributes.
    unsigned int size;
    unsigned char read_latency_cycles;
    enum qspi_flash_erase_block_size erase_block_size;
    enum qspi_flash_page_size page_size;
};

static char s25flxxxs_reset(void * qspi_flash_device)
{
    (void) qspi_flash_device;

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

static char s25flxxxs_init(void * qspi_flash_device)
{
    struct s25flxxxs * self = (struct s25flxxxs *) qspi_flash_device;
    const uint8_t spi_tx[] = {0x9f};
    uint8_t spi_rx[44] = {0x00};
    unsigned char cr1;
    BOOL quad_mode_enabled;

    // Software reset.
    if (s25flxxxs_reset(qspi_flash_device) != 0)
    {
        return -1;
    }

#ifdef QSPI_VERBOSE
    mhx_writef("Registers = %02X %02X %02X\n", read_status_register_1(), read_status_register_2(), read_configuration_register_1());
#endif

    // Read RDID to confirm manufacturer and model, and get density.
    spi_transaction(spi_tx, 1, spi_rx, 44);

#ifdef QSPI_VERBOSE
    mhx_writef("CFI = %02X %02X %02X %02X %02X %02X\n", spi_rx[0], spi_rx[1], spi_rx[2], spi_rx[3], spi_rx[4], spi_rx[42]);
#endif

    if (spi_rx[0] != 0x01)
    {
        return -1;
    }

    if (spi_rx[1] == 0x20 && spi_rx[2] == 0x18)
    {
        // 128 Mb == 16 MB.
        self->size = 16;
    }
    else if (spi_rx[1] == 0x02 && spi_rx[2] == 0x19)
    {
        // 256 Mb == 32 MB.
        self->size = 32;
    }
    else if (spi_rx[1] == 0x02 && spi_rx[2] == 0x20)
    {
        // 512 Mb == 64 MB.
        self->size = 64;
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
        self->erase_block_size = qspi_flash_erase_block_size_256k;
    }
    else if (spi_rx[4] == 0x01)
    {
        // Mixed 4K / 64K sectors.
        self->erase_block_size = qspi_flash_erase_block_size_64k;
    }
    else
    {
        return -1;
    }

    cr1 = read_configuration_register_1();
    self->read_latency_cycles = ((cr1 >> 6) == 3) ? 0 : 8;

    // Determine page size.
    if (spi_rx[42] == 0x08)
    {
        // Page size 256 bytes.
        self->page_size = qspi_flash_page_size_256;
    }
    else if (spi_rx[42] == 0x09)
    {
        // Page size 512 bytes.
        self->page_size = qspi_flash_page_size_512;
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
        if (!quad_mode_enabled)
        {
            return -1;
        }
    }

#ifdef QSPI_VERBOSE
    mhx_writef("Flash size = %d MB\n", self->size);
    mhx_writef("Latency cycles = %d\n", self->read_latency_cycles);
    mhx_writef("Sector size (K) = %d\n", (self->erase_block_size == qspi_flash_erase_block_size_256k) ? 256 : 64);
    mhx_writef("Page size = %d\n", (self->page_size == qspi_flash_page_size_256) ? 256 : 512);
    mhx_writef("Quad mode = %d\n", quad_mode_enabled ? 1 : 0);
    mhx_writef("Registers = %02X %02X %02X\n", read_status_register_1(), read_status_register_2(), read_configuration_register_1());
#endif

    return 0;
}

static char s25flxxxs_read(void * qspi_flash_device, unsigned long address, unsigned char * data, unsigned int size)
{
    const struct s25flxxxs * self = (const struct s25flxxxs *) qspi_flash_device;

    spi_clock_high();
    spi_cs_low();
    spi_output_enable();
    spi_tx_byte(0x6c);
    spi_tx_byte(address >> 24);
    spi_tx_byte(address >> 16);
    spi_tx_byte(address >> 8);
    spi_tx_byte(address >> 0);
    spi_output_disable();
    spi_idle_clocks(self->read_latency_cycles);
    if (data == NULL)
    {
        unsigned int i;

        for (i = 0; i < size; ++i)
        {
            qspi_rx_byte();
        }
    }
    else
    {
        unsigned int i;

        for (i = 0; i < size; ++i)
        {
            data[i] = qspi_rx_byte();
        }
    }
    spi_cs_high();
    spi_clock_high();
    return 0;
}

static char s25flxxxs_verify(void * qspi_flash_device, unsigned long address, unsigned char * data, unsigned int size)
{
    const struct s25flxxxs * self = (const struct s25flxxxs *) qspi_flash_device;
    char result = 0;

    spi_clock_high();
    spi_cs_low();
    spi_output_enable();
    spi_tx_byte(0x6c);
    spi_tx_byte(address >> 24);
    spi_tx_byte(address >> 16);
    spi_tx_byte(address >> 8);
    spi_tx_byte(address >> 0);
    spi_output_disable();
    spi_idle_clocks(self->read_latency_cycles);
    if (data == NULL)
    {
        unsigned int i;

        for (i = 0; i < size; ++i)
        {
            if (qspi_rx_byte() != 0)
            {
                result = -1;
                break;
            }
        }
    }
    else
    {
        unsigned int i;

        for (i = 0; i < size; ++i)
        {
            if (qspi_rx_byte() != data[i])
            {
                result = -1;
                break;
            }
        }
    }
    spi_cs_high();
    spi_clock_high();
    return result;
}

static char s25flxxxs_erase(void * qspi_flash_device, enum qspi_flash_erase_block_size erase_block_size, unsigned long address)
{
    const struct s25flxxxs * self = (const struct s25flxxxs *) qspi_flash_device;

    if (erase_block_size != self->erase_block_size)
    {
        return -1;
    }

    return erase_sector(address);
}

static char s25flxxxs_program(void * qspi_flash_device, enum qspi_flash_page_size page_size, unsigned long address, const unsigned char * data)
{
    const struct s25flxxxs * self = (const struct s25flxxxs *) qspi_flash_device;
    unsigned int page_size_bytes = (self->page_size == qspi_flash_page_size_256) ? 256 : 512;
    unsigned int i;

    if (page_size != self->page_size)
    {
        // Unsupported page size.
        return -1;
    }

    if (data == NULL)
    {
        // Invalid data pointer.
        return -1;
    }

    if (address & 0xff)
    {
        // Address not aligned to page boundary.
        return -1;
    }

    if ((address & 0x1ff) && (self->page_size != qspi_flash_page_size_256))
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
    for (i = 0; i < page_size_bytes; ++i)
    {
        qspi_tx_byte(data[i]);
    }
    spi_output_disable();
    spi_cs_high();
    spi_clock_high();

    return wait_status();
}

static char s25flxxxs_get_manufacturer(void * qspi_flash_device, const char ** manufacturer)
{
    (void) qspi_flash_device;
    *manufacturer = "infineon";
    return 0;
}

static char s25flxxxs_get_size(void * qspi_flash_device, unsigned int * size)
{
    const struct s25flxxxs * self = (const struct s25flxxxs *) qspi_flash_device;
    *size = self->size;
    return 0;
}

static char s25flxxxs_get_page_size(void * qspi_flash_device, enum qspi_flash_page_size * page_size)
{
    const struct s25flxxxs * self = (const struct s25flxxxs *) qspi_flash_device;
    *page_size = self->page_size;
    return 0;
}

static char s25flxxxs_get_erase_block_size_support(void * qspi_flash_device, enum qspi_flash_erase_block_size erase_block_size, BOOL * is_supported)
{
    const struct s25flxxxs * self = (const struct s25flxxxs *) qspi_flash_device;
    *is_supported = (self->erase_block_size == erase_block_size);
    return 0;
}

static struct s25flxxxs _s25flxxxs = {{
    s25flxxxs_init,
    s25flxxxs_read,
    s25flxxxs_verify,
    s25flxxxs_erase,
    s25flxxxs_program,
    s25flxxxs_get_manufacturer,
    s25flxxxs_get_size,
    s25flxxxs_get_page_size,
    s25flxxxs_get_erase_block_size_support
}};

void * s25flxxxs = & _s25flxxxs;
