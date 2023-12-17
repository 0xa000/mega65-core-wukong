#include <hal.h>
#include <memory.h>
#include <stdio.h>

#include "qspiflash.h"
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

static unsigned char read_configuration_register_2(void)
{
    return spi_transaction_tx8rx8(0x15);
}

static unsigned char read_configuration_register_3(void)
{
    return spi_transaction_tx8rx8(0x33);
}

static void write_enable(void)
{
    spi_transaction_tx8(0x06);
}

static void clear_status_register(void)
{
    spi_transaction_tx8(0x30);
}

struct s25flxxxl_status
{
    unsigned char sr1;
    unsigned char sr2;
};

static struct s25flxxxl_status read_status(void)
{
    struct s25flxxxl_status status;
    status.sr1 = read_status_register_1();
    status.sr2 = read_status_register_2();
    return status;
}

static BOOL erase_error_occurred(const struct s25flxxxl_status * status)
{
    return (status->sr2 & 0x40 ? TRUE : FALSE);
}

static BOOL program_error_occurred(const struct s25flxxxl_status * status)
{
    return (status->sr2 & 0x20 ? TRUE : FALSE);
}

static BOOL write_enabled(const struct s25flxxxl_status * status)
{
    return (status->sr1 & 0x02 ? TRUE : FALSE);
}

static BOOL write_in_progress(const struct s25flxxxl_status * status)
{
    return (status->sr1 & 0x01 ? TRUE : FALSE);
}

static BOOL busy(const struct s25flxxxl_status * status)
{
    return (status->sr1 & 0x03 ? TRUE : FALSE);
}

static BOOL error_occurred(const struct s25flxxxl_status * status)
{
    return (status->sr2 & 0x60 ? TRUE : FALSE);
}

static void clear_status(void)
{
    struct s25flxxxl_status status;
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
    struct s25flxxxl_status status;
    for (;;)
    {
        status = read_status();
        if (!busy(&status))
            break;
    }
    return (error_occurred(&status) ? -1 : 0);
}

struct s25flxxxl
{
    // Interface.
    const struct qspi_flash_interface interface;
    // Attributes.
    unsigned char read_latency_cycles;
};

static char s25flxxxl_reset(void * self)
{
    (void) self;

    spi_cs_high();
    spi_clock_high();

    usleep(10000);

    // Allow lots of clock ticks to get attention of SPI
    spi_idle_clocks(255);

    // Reset enable.
    spi_transaction_tx8(0x66);

    // Reset.
    spi_transaction_tx8(0x99);

    usleep(10000);
    return 0;
}

static void volatile_write_enable(void)
{
    spi_transaction_tx8(0x50);
}

static char enable_quad_mode(void)
{
    unsigned char spi_tx[] = {0x01, 0x00, 0x00};

    spi_tx[1] = read_status_register_1();
    spi_tx[2] = read_configuration_register_1();
    spi_tx[2] |= 0x02;

    volatile_write_enable();
    spi_transaction(spi_tx, 3, NULL, 0);
    return wait_status();
}

static char s25flxxxl_probe(void * self, struct qspi_flash_descriptor * descriptor)
{
    const uint8_t spi_tx[] = {0x9f};
    uint8_t spi_rx[] = {0x00, 0x00, 0x00};
    unsigned char cr1, cr2, cr3;
    BOOL quad_mode_enabled;
    struct s25flxxxl * self_ = (struct s25flxxxl *) self;

    if (s25flxxxl_reset(self) != 0)
        return -1;

    // Read RDID to confirm model and get density.
    spi_transaction(spi_tx, 1, spi_rx, 3);
    if (spi_rx[0] != 0x01 || spi_rx[1] != 0x60)
        return -1;

    descriptor->manufacturer = "infineon";
    if (spi_rx[2] == 0x18)
        // 128 Mb
        descriptor->memory_size_mb = 16;
    else if (spi_rx[2] == 0x19)
        // 256 Mb
        descriptor->memory_size_mb = 32;
    else
        return -1;

    descriptor->uniform_sector_sizes[qspi_flash_sector_size_4k  ] = TRUE;
    descriptor->uniform_sector_sizes[qspi_flash_sector_size_32k ] = TRUE;
    descriptor->uniform_sector_sizes[qspi_flash_sector_size_64k ] = TRUE;
    descriptor->uniform_sector_sizes[qspi_flash_sector_size_256k] = FALSE;

    descriptor->page_size = qspi_flash_page_size_256;

    cr1 = read_configuration_register_1();
    cr2 = read_configuration_register_2();
    cr3 = read_configuration_register_3();

    self_->read_latency_cycles = cr3 & 0x0f;

    quad_mode_enabled = cr1 & 0x02;
    if (!quad_mode_enabled)
    {
        if (enable_quad_mode() != 0)
           return -1;
        cr1 = read_configuration_register_1();
        quad_mode_enabled = cr1 & 0x02;
    }

    if (!quad_mode_enabled)
    {
        return -1;
    }

    descriptor->read_latency_cycles = self_->read_latency_cycles;
    descriptor->quad_mode_enabled = quad_mode_enabled;
    descriptor->memory_array_protection_enabled = ((cr2 & 0x04) || (cr1 & 0x3c)) ? TRUE : FALSE;
    descriptor->register_protection_enabled = (cr1 & 0x01) ? TRUE : FALSE;

    return 0;
}

static char s25flxxxl_read(void * self, unsigned long address, unsigned char * data, unsigned int size)
{
    const struct s25flxxxl * self_ = (const struct s25flxxxl *) self;

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

static char s25flxxxl_verify(void * self, unsigned long address, unsigned char * data, unsigned int size)
{
    const struct s25flxxxl * self_ = (const struct s25flxxxl *) self;
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
    spi_idle_clocks(self_->read_latency_cycles);
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

static char s25flxxxl_erase_sector(void * self, enum qspi_flash_sector_size sector_size, unsigned long address)
{
    unsigned char spi_tx[5];

    (void) self;

    switch (sector_size)
    {
    case qspi_flash_sector_size_4k:
        spi_tx[0] = 0x21;
        break;
    case qspi_flash_sector_size_32k:
        spi_tx[0] = 0x53;
        break;
    case qspi_flash_sector_size_64k:
        spi_tx[0] = 0xdc;
        break;
    default:
        return -1;
    }

    spi_tx[1] = address >> 24;
    spi_tx[2] = address >> 16;
    spi_tx[3] = address >> 8;
    spi_tx[4] = address >> 0;

    clear_status();
    write_enable();
    spi_transaction(spi_tx, 5, NULL, 0);
    return wait_status();
}

static char s25flxxxl_program_page(void * self, unsigned long address, const unsigned char * data)
{
    unsigned int i = 0;

    (void) self;

    if (data == NULL)
    {
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
    for (i = 0; i < 256; ++i)
    {
        qspi_tx_byte(data[i]);
    }
    spi_output_disable();
    spi_cs_high();
    spi_clock_high();
    return wait_status();
}

static struct s25flxxxl _s25flxxxl = {
    {s25flxxxl_reset, s25flxxxl_probe, s25flxxxl_read, s25flxxxl_verify, s25flxxxl_erase_sector, s25flxxxl_program_page}
};

void * s25flxxxl = & _s25flxxxl;
