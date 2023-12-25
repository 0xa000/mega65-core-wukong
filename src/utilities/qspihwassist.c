#include <memory.h>
#include <stddef.h>

#include "qspihwassist.h"
#include "qspibitbash.h"

void hw_assisted_read_512(unsigned long address, unsigned char * data)
{
    // unsigned char b;
    // SPI command byte 0x6C.
    // Full hardware-acceleration of reading, which is both faster
    // and more reliable.
    POKE(0xD681, address >> 0);
    POKE(0xD682, address >> 8);
    POKE(0xD683, address >> 16);
    POKE(0xD684, address >> 24);
    POKE(0xD680, 0x5f); // Set number of dummy cycles
    POKE(0xD680, 0x53); // QSPI Flash Sector read command
    // // XXX For some reason the busy flag is broken here.
    // // So just wait a little while, but only a little while
    // for (b = 0; b < 180; b++)
    // {
    //     continue;
    // }
    while (PEEK(0xD680) & 3)
    {
        POKE(0xD020, PEEK(0xD020) + 1);
    }

    // Tristate and release CS at the end
    // POKE(BITBASH_PORT, 0xff);
    if (data != NULL)
    {
        lcopy(0xFFD6E00L, (unsigned long)data, 512);
    }
}

void hw_assisted_erase_sector(unsigned long address)
{
    // SPI command byte 0xDC.
    POKE(0xD681, address >> 0);
    POKE(0xD682, address >> 8);
    POKE(0xD683, address >> 16);
    POKE(0xD684, address >> 24);
    POKE(0xd680, 0x58);
    while (PEEK(0xD680) & 3)
    {
        POKE(0xD020, PEEK(0xD020) + 1);
    }
}

void hw_assisted_program_page_512(unsigned long address, const unsigned char * data)
{
    // SPI command byte 0x34.
    lcopy((unsigned long)data, 0XFFD6E00L, 512);
    POKE(0xD681, address >> 0);
    POKE(0xD682, address >> 8);
    POKE(0xD683, address >> 16);
    POKE(0xD684, address >> 24);
    POKE(0xD680, 0x54);
    while (PEEK(0xD680) & 3)
    {
        POKE(0xD020, PEEK(0xD020) + 1);
    }
}

void hw_assisted_program_page_256(unsigned long address, const unsigned char * data)
{
    // SPI command byte 0x34.
    // NB. Command 0x55 (U) writes the *last* 256 bytes of the SD card buffer to
    // flash!
    lcopy((unsigned long)data, 0XFFD6F00L, 256);
    POKE(0xD681, address >> 0);
    POKE(0xD682, address >> 8);
    POKE(0xD683, address >> 16);
    POKE(0xD684, address >> 24);
    POKE(0xD680, 0x55);
    while (PEEK(0xD680) & 3)
    {
        POKE(0xD020, PEEK(0xD020) + 1);
    }
}

void hw_assisted_cfi_block_read(unsigned char *data)
{
    unsigned int i;
    // SPI command byte 0x9B.
    // Hardware acclerated CFI block read
    POKE(0xD6CD, 0x02);
    // spi_cs_high();
    POKE(0xD680, 0x6B);
    // Give time to complete
    for (i = 0; i < 512; i++)
    {
        continue;
    }
    // spi_cs_high();

    lcopy(0XFFD6E00L, (unsigned long)data, 512);
}

// TODO: Function to erase a sector using SPI command 0xdc; POKE 0x58 to $D680.
//
// void hw_assisted_erase_sector(unsigned long address)
// {
//     // SPI command byte 0xDC.
//     // Do 64KB/256KB sector erase
//     //    mhx_writef("erasing large sector.\n");
//     POKE(0xD681, address >> 0);
//     POKE(0xD682, address >> 8);
//     POKE(0xD683, address >> 16);
//     POKE(0xD684, address >> 24);
//     // Erase large page
//     POKE(0xd680, 0x58);
// }

// TODO: Function to erase a sector using SPI command 0x21; POKE 0x59 to $D680.
//
// void hw_assisted_erase_parameter_sector(unsigned long address)
// {
//     // SPI command byte 0x21.
//     // JVZ: Seems we can also POKE 0x59 to $D680 for this?
//     spi_cs_high();
//     spi_clock_high();
//     delay();
//     spi_cs_low();
//     delay();
//
//     // Do fast 4KB sector erase
//     spi_tx_byte(0x21);
//     spi_tx_byte(address >> 24);
//     spi_tx_byte(address >> 16);
//     spi_tx_byte(address >> 8);
//     spi_tx_byte(address >> 0);
// }

// TODO: Function to verify in place; POKE 0x56 to $D680.
//
// char verify_data_in_place(unsigned long address)
// {
//     // SPI command byte 0x6C.
//     unsigned char b;
//     POKE(0xd020, 1);
//     POKE(0xD681, address >> 0);
//     POKE(0xD682, address >> 8);
//     POKE(0xD683, address >> 16);
//     POKE(0xD684, address >> 24);
//     POKE(0xD680, 0x5f); // Set number of dummy cycles
//     POKE(0xD680, 0x56); // QSPI Flash Sector verify command
//     // XXX For some reason the busy flag is broken here.
//     // So just wait a little while, but only a little while
//     for (b = 0; b < 180; b++)
//         continue;
//     POKE(0xd020, 0);
//
//     // 0 = verify success, -1 = verify failure
//     if (PEEK(0xD689) & 0x40)
//         return -1;
//
//     return 0;
// }

// TODO: Function to set number of dummy cycles; POKE 0x5a .. 0x5f to $D680.
//
// when x"5a" => qspi_command_len <= 90;
// when x"5b" => qspi_command_len <= 92;
// when x"5c" => qspi_command_len <= 94;
// when x"5d" => qspi_command_len <= 96;
// when x"5e" => qspi_command_len <= 98;
// when x"5f" => qspi_command_len <= 100;

// TODO: Function to set write enable using SPI command 0x06; POKE 0x66 to $D680.

// TODO: Function to clear status register using SPI command 0x30; POKE 0x6a to $D680.
