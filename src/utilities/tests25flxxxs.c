#include <stdio.h>
#include <string.h>

#include <hal.h>
#include <memory.h>
#include <dirent.h>
#include <time.h>

#include <6502.h>

#include "mhexes.h"
#include "qspiflash.h"
#include "qspihwassist.h"
#include "qspibitbash.h"
#include "s25flxxxl.h"
#include "s25flxxxs.h"

void * qspi_flash_device = NULL;

/*
  TODO
  =====
  Time each operation.
  Check hardware assisted operations (needs modified core).
*/

static unsigned char buffer[512];

static void flash_inspector(unsigned long address)
{
    short i, x;

    while (1)
    {
        qspi_flash_read(qspi_flash_device, address, buffer, 256);
        mhx_clearscreen(' ', MHX_A_WHITE);
        mhx_set_xy(0, 0);
        mhx_writef("Flash @ $%08lx:\n", address);
        for (i = 0; i < 256; i++)
        {
            if (!(i & 15))
                mhx_writef("+%03x : ", i);
            mhx_writef("%02x", buffer[i]);
            if ((i & 15) == 15)
                mhx_writef("\n");
        }

        x = 0;
        while (!x)
        {
            x = PEEK(0xd610);
        }

        POKE(0xd610, 0);

        if (x)
        {
            switch (x)
            {
            case 0x13:
                address = 0;
                break;
            case 0x51:
            case 0x71:
                address -= 0x10000;
                break;
            case 0x41:
            case 0x61:
                address += 0x10000;
                break;
            case 0x11:
            case 0x44:
            case 0x64:
                address += 256;
                break;
            case 0x91:
            case 0x55:
            case 0x75:
                address -= 256;
                break;
            case 0x1d:
            case 0x52:
            case 0x72:
                address += 0x400000;
                break;
            case 0x9d:
            case 0x4c:
            case 0x6c:
                address -= 0x400000;
                break;
            case 0x03:
                return;
            }
        }
    }
}

static char qspi_is_empty(unsigned long address, unsigned int num_pages)
{
    unsigned int i;
    unsigned int j;

    for (i = 0; i < num_pages; ++i)
    {
        qspi_flash_read(qspi_flash_device, address, buffer, 256);

        for (j = 0; j <= 255; ++j)
        {
            if (buffer[j] != 0xff)
            {
                return -1;
            }
        }

        address += 256UL;
    }

    return 0;
}

static void hard_exit(void)
{
    // clear keybuffer
    *(unsigned char *)0xc6 = 0;

    // Switch back to normal speed control before exiting
    POKE(0, 64);
    mhx_screencolor(MHX_A_BLUE, MHX_A_LBLUE);
    mhx_clearscreen(' ', MHX_A_WHITE);
    // call NMI vector
    asm(" jmp ($fffa) ");
}

char test_erase_program_erase(unsigned long address)
{
    enum qspi_flash_page_size page_size;
    unsigned int page_size_bytes;
    enum qspi_flash_erase_block_size max_erase_block_size;
    unsigned long erase_block_size_bytes;
    unsigned int erase_block_size_pages;
    unsigned int i;

    mhx_clearscreen(' ', MHX_A_WHITE);
    mhx_set_xy(0, 1);

    if (get_max_erase_block_size(qspi_flash_device, &max_erase_block_size) != 0)
    {
        hard_exit();
    }

    if (get_erase_block_size_in_bytes(max_erase_block_size, &erase_block_size_bytes) != 0)
    {
        hard_exit();
    }

    if (qspi_flash_get_page_size(qspi_flash_device, &page_size) != 0)
    {
        hard_exit();
    }

    if (get_page_size_in_bytes(page_size, &page_size_bytes) != 0)
    {
        hard_exit();
    }

    erase_block_size_pages = erase_block_size_bytes >> 8;

    mhx_writef("Address = $%08lx\n", address);
    mhx_writef("Page size = %u\n", page_size_bytes);
    mhx_writef("Erase block size (bytes) = %lu\n", erase_block_size_bytes);
    mhx_writef("Erase block size (pages) = %u\n\n", erase_block_size_pages);

    if (qspi_flash_erase(qspi_flash_device, max_erase_block_size, address) != 0)
    {
        mhx_writef("\n" MHX_W_RED "ERROR: Unable to erase block!" MHX_W_WHITE "\n\n");
        mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
        return -1;
    }

    mhx_writef("Erase block... OK\n");

    if (qspi_is_empty(address, erase_block_size_pages) != 0)
    {
        mhx_writef("\n" MHX_W_RED "ERROR: Erased block not empty!" MHX_W_WHITE "\n\n");
        mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
        return -1;
    }

    mhx_writef("Erase block verify... OK\n");

    for (i = 0; i < 512; ++i)
    {
        unsigned char b = (255 - (i >> 1));
        if (i & 1)
        {
            b = ~b;
        }
        buffer[i] = b;
    }

    if (qspi_flash_program(qspi_flash_device, page_size, address, buffer) != 0)
    {
        mhx_writef("\n" MHX_W_RED "ERROR: Programming failed!" MHX_W_WHITE "\n\n");
        mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
        return -1;
    }

    mhx_writef("Program page... OK\n");

    if (qspi_flash_verify(qspi_flash_device, address, buffer, page_size_bytes) != 0)
    {
        mhx_writef("\n" MHX_W_RED "ERROR: Verification failed!" MHX_W_WHITE "\n\n");
        mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
        return -1;
    }

    mhx_writef("Verify page... OK\n");

    if (qspi_flash_erase(qspi_flash_device, max_erase_block_size, address) != 0)
    {
        mhx_writef("\n" MHX_W_RED "ERROR: Unable to erase block!" MHX_W_WHITE "\n\n");
        mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
        return -1;
    }

    mhx_writef("Erase block... OK\n");

    if (qspi_is_empty(address, erase_block_size_pages) != 0)
    {
        mhx_writef("\n" MHX_W_RED "ERROR: Erased block not empty!" MHX_W_WHITE "\n\n");
        mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
        return -1;
    }

    mhx_writef("Erase block verify... OK\n\n");

    mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
    return 0;
}

void main(void)
{
    unsigned int size;
    enum qspi_flash_page_size page_size;
    unsigned int page_size_bytes;
    BOOL erase_block_sizes[qspi_flash_erase_block_size_last];
    unsigned int i;

    mega65_io_enable();

    SEI();

    qspi_flash_device = s25flxxxs;

    // white text, blue screen, black border, clear screen
    mhx_screencolor(MHX_A_BLUE, MHX_A_BLACK);
    mhx_clearscreen(' ', MHX_A_WHITE);
    mhx_set_xy(0, 1);

    mhx_writef(MHX_W_WHITE "Hardware Model ID = %02X\n\n", PEEK(0xD629));

    mhx_writef("Accessing QSPI flash chip...\n\n");
    if (qspi_flash_init(qspi_flash_device))
    {
        mhx_writef("\n" MHX_W_RED "ERROR: Unable to access QSPI flash chip!" MHX_W_WHITE "\n\n");
        mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
        hard_exit();
    }

    if (qspi_flash_get_size(qspi_flash_device, &size) != 0)
    {
        hard_exit();
    }

    if (qspi_flash_get_page_size(qspi_flash_device, &page_size) != 0)
    {
        hard_exit();
    }

    if (get_page_size_in_bytes(page_size, &page_size_bytes) != 0)
    {
        hard_exit();
    }

    for (i = 0; i < qspi_flash_erase_block_size_last; ++i)
    {
        if (qspi_flash_get_erase_block_size_support(qspi_flash_device, (enum qspi_flash_erase_block_size) i, &erase_block_sizes[i]) != 0)
        {
            hard_exit();
        }
    }

    mhx_writef("\n");
    mhx_writef("Flash size  = %u MB\n", size);
    mhx_writef("Erase sizes =");
    if (erase_block_sizes[qspi_flash_erase_block_size_4k])
        mhx_writef(" 4K");
    if (erase_block_sizes[qspi_flash_erase_block_size_32k])
        mhx_writef(" 32K");
    if (erase_block_sizes[qspi_flash_erase_block_size_64k])
        mhx_writef(" 64K");
    if (erase_block_sizes[qspi_flash_erase_block_size_256k])
        mhx_writef(" 256K");
    mhx_writef("\n");
    mhx_writef("Page size   = %u\n", page_size_bytes);
    mhx_writef("\n");
    mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);

    mhx_clearscreen(' ', MHX_A_WHITE);
    mhx_set_xy(0, 1);
    mhx_writef(MHX_W_YELLOW
               "WARNING: Slot 0 will be clobbered!\n"
               "Do not continue unless you know how to\n"
               "use a JTAG adapter to restore slot 0!\n\n"
               MHX_W_WHITE);
    usleep(1000000UL);
    mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);

    if (test_erase_program_erase(0x00000UL) != 0)
    {
        flash_inspector(0x00000UL);
        hard_exit();
    }

    if (test_erase_program_erase(0x80000UL) != 0)
    {
        flash_inspector(0x80000UL);
        hard_exit();
    }

    mhx_clearscreen(' ', MHX_A_WHITE);
    mhx_set_xy(0, 1);
    mhx_writef("DONE!\n\n");
    mhx_press_any_key(MHX_AK_IGNORETAB, MHX_A_WHITE);
    hard_exit();
}
