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

// #include <cbm_petscii_charmap.h>
// #include <cbm_screen_charmap.h>

void * qspi_flash_device = NULL;

static unsigned char read_status_register_1(void)
{
    return spi_transaction_tx8rx8(0x05);
}

static unsigned char read_status_register_2(void)
{
    return spi_transaction_tx8rx8(0x07);
}

static void clear_status_register(void)
{
    spi_transaction_tx8(0x30);
}

static BOOL erase_error_occurred(unsigned char sr2)
{
    return (sr2 & 0x40 ? TRUE : FALSE);
}

static BOOL program_error_occurred(unsigned char sr2)
{
    return (sr2 & 0x20 ? TRUE : FALSE);
}

static BOOL busy(const unsigned char sr1)
{
    return (sr1 & 0x03 ? TRUE : FALSE);
}

static BOOL error_occurred(unsigned char sr2)
{
    return (sr2 & 0x60 ? TRUE : FALSE);
}

static void clear_status(void)
{
    unsigned char sr1, sr2;
    for (;;)
    {
        sr1 = read_status_register_1();
        sr2 = read_status_register_2();
        if (!busy(sr1) && !error_occurred(sr2))
        {
            break;
        }
        clear_status_register();
    }
}

static char wait_status(void)
{
    unsigned char sr1, sr2;
    for (;;)
    {
        sr1 = read_status_register_1();
        if (!busy(sr1))
        {
            break;
        }
    }

    sr2 = read_status_register_2();
    return (error_occurred(sr2) ? -1 : 0);
}

static void write_enable(void)
{
    spi_transaction_tx8(0x06);
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

void main(void)
{
  unsigned char data_buffer_sw[512];
  unsigned char data_buffer_hw[512];
  unsigned long address = 0x400000;
  BOOL quit = FALSE;
  BOOL init = FALSE;
  BOOL read_sw = FALSE;
  BOOL read_hw = FALSE;
  BOOL erase = FALSE;
  BOOL program = FALSE;

  mega65_io_enable();

  SEI();

  // white text, blue screen, black border, clear screen
  // POKE(0xD018, 23);
  mhx_screencolor(MHX_A_BLUE, MHX_A_BLACK);
  mhx_clearscreen(' ', MHX_A_WHITE);
  mhx_set_xy(0, 0);

  qspi_flash_device = s25flxxxl;

  if (qspi_flash_init(qspi_flash_device) != 0)
  {
    mhx_writef("\n\n" MHX_W_RED "ERROR: Flash initialization failed." MHX_W_WHITE "\n");
    mhx_press_any_key(MHX_AK_ATTENTION|MHX_AK_NOMESSAGE, MHX_A_NOCOLOR);
    hard_exit();
  }

  // when x"67" =>
  //   qspi_release_cs_on_completion_enable <= '0';
  // when x"68" =>
  //   qspi_release_cs_on_completion_enable <= '1';

  while (!quit)
  {
    unsigned char x;

    mhx_clearscreen(' ', MHX_A_WHITE);
    mhx_set_xy(0, 0);

    mhx_writef(MHX_W_WHITE "\n\nAddress = $%08lx\n\n", address);

    if (init)
    {
      mhx_writef("Init flash... ");
      if (qspi_flash_init(qspi_flash_device) != 0)
      {
        mhx_writef(MHX_W_RED "ERROR" MHX_W_WHITE "\n");
      }
      else
      {
        mhx_writef("OK\n");
      }
    }

    if (erase)
    {
      mhx_writef("Hardware-assisted erase sector...");
      clear_status();
      write_enable();
      hw_assisted_erase_sector(address);
      if (wait_status() != 0)
      {
        mhx_writef(MHX_W_RED "ERROR" MHX_W_WHITE "\n");
      }
      else
      {
        mhx_writef("OK\n");
      }
    }

    if (program)
    {
      unsigned int i;
      for (i = 0; i < 256; ++i)
      {
        unsigned char b = (255 - i);
        if (i & 1)
        {
          b = ~b;
        }
        data_buffer_hw[i] = b;
      }
      mhx_writef("Hardware-assisted program page...");
      clear_status();
      write_enable();
      hw_assisted_program_page_256(address, data_buffer_hw);
      if (wait_status() != 0)
      {
        mhx_writef(MHX_W_RED "ERROR" MHX_W_WHITE "\n");
      }
      else
      {
        mhx_writef("OK\n");
      }
    }

    if (read_sw)
    {
      mhx_writef(MHX_W_WHITE "Software read... ");
      lfill((unsigned long)data_buffer_sw, 0xaa, 512);
      if (qspi_flash_read(qspi_flash_device, address, data_buffer_sw, 512) != 0)
      {
        mhx_writef(MHX_W_RED "ERROR" MHX_W_WHITE "\n");
      }
      else
      {
        mhx_writef("OK\n");
      }
    }

    if (read_hw)
    {
      mhx_writef("Hardware-assisted read... ");
      lfill((unsigned long)data_buffer_hw, 0, 512);
      // Release CS (hardware implementation does not de-assert).
      spi_cs_high();
      hw_assisted_read_512(address, data_buffer_hw);
      mhx_writef("OK\n");
    }

    if (read_sw || read_hw)
    {
      unsigned char * data_buffer = read_sw ? data_buffer_sw : data_buffer_hw;
      unsigned int i = 0;

      mhx_writef("Flash @ $%08lx:\n", address);
      for (i = 0; i < 256; i++)
      {
        if (!(i & 15))
          mhx_writef("+%03x : ", i);
        mhx_writef("%02x", data_buffer[i]);
        if ((i & 15) == 15)
          mhx_writef("\n");
      }
    }

    init = FALSE;
    read_sw = FALSE;
    read_hw = FALSE;
    erase = FALSE;
    program = FALSE;

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
        address = 0x400000;
        break;
      case 0x51: // Q
      case 0x71:
        address -= 0x10000;
        break;
      case 0x41: // A
      case 0x61:
        address += 0x10000;
        break;
      case 0x11: // down-arrow
      case 0x44: // D
      case 0x64:
        address += 256;
        break;
      case 0x91: // shift + down-arrow
      case 0x55: // U
      case 0x75:
        address -= 256;
        break;
      // case 0x1d: // right-arrow
      // case 0x52: // R
      // case 0x72:
      //   address += 0x400000;
      //   break;
      // case 0x9d: // shift + right-arrow
      // case 0x4c: // L
      // case 0x6c:
      //   address -= 0x400000;
      //   break;
      case 0x48: // H
      case 0x68:
        read_hw = TRUE;
        break;
      case 0x53: // S
      case 0x73:
        read_sw = TRUE;
        break;
      case 0x49: // I
      case 0x69:
        init = TRUE;
        break;
      case 0x45: // E
      case 0x65:
        erase = TRUE;
        break;
      case 0x50: // P
      case 0x70:
        program = TRUE;
        break;
      case 0x03: // Run-stop
        quit = TRUE;
        break;
      }
    }
  }

  hard_exit();
}
