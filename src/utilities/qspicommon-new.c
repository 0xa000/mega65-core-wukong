#include <stdio.h>
#include <string.h>

#include <hal.h>
#include <memory.h>
#include <dirent.h>

#include "qspicommon-new.h"
#include "qspireconfig.h"
#include "qspiflash.h"
#include "s25flxxxl.h"
#include "s25flxxxs.h"
#include "mhexes.h"
#include "crc32accl.h"
#include "nohysdc.h"
#include "mf_selectcore.h"

#include <cbm_screen_charmap.h>

unsigned char slot_count = 0;

#ifdef STANDALONE
uint8_t SLOT_MB = 1;
unsigned long SLOT_SIZE = 1L << 20;
unsigned long SLOT_SIZE_PAGES = 1L << 12;
#endif

short i, x, y, z;

unsigned long addr, addr_len;
unsigned char tries = 0;

unsigned int num_4k_sectors = 0;

unsigned char verboseProgram = 0;

unsigned char part[256];

unsigned int page_size = 0;
unsigned char latency_code = 0xff;
unsigned char reg_cr1 = 0x00;
unsigned char reg_sr1 = 0x00;

unsigned char manufacturer;
unsigned short device_id;
unsigned char cfi_data[512];
unsigned short cfi_length = 0;
unsigned char flash_sector_bits = 0;
unsigned char last_sector_num = 0xff;
unsigned char sector_num = 0xff;

// used by QSPI routines
unsigned char data_buffer[512];
// used by SD card routines
unsigned char buffer[512];

uint8_t hw_model_id = 0;
char *hw_model_name = "?unknown?";

unsigned short mb = 0;

void * qspi_flash_device;

/***************************************************************************

 FPGA / Core file / Hardware platform routines

 ***************************************************************************/

// clang-format off
models_type mega_models[] = {
  { 0x01, 8, qspi_flash_device_type_s25flxxxs, "MEGA65 R1"        },
  { 0x02, 4, qspi_flash_device_type_s25flxxxs, "MEGA65 R2"        },
  { 0x03, 8, qspi_flash_device_type_s25flxxxs, "MEGA65 R3"        },
  { 0x04, 8, qspi_flash_device_type_s25flxxxs, "MEGA65 R4"        },
  { 0x05, 8, qspi_flash_device_type_s25flxxxs, "MEGA65 R5"        },
  { 0x21, 4, qspi_flash_device_type_s25flxxxs, "MEGAphone R1"     },
  { 0x22, 4, qspi_flash_device_type_s25flxxxs, "MEGAphone R4"     },
  { 0x40, 4, qspi_flash_device_type_s25flxxxs, "Nexys4"           },
  { 0x41, 4, qspi_flash_device_type_s25flxxxs, "Nexys4DDR"        },
  { 0x42, 4, qspi_flash_device_type_s25flxxxs, "Nexys4DDR-widget" },
  { 0x60, 4, qspi_flash_device_type_s25flxxxl, "QMTECH A100T"     },
  { 0x61, 8, qspi_flash_device_type_s25flxxxl, "QMTECH A200T"     },
  { 0x62, 8, qspi_flash_device_type_s25flxxxl, "QMTECH A325T"     },
  { 0xFD, 4, qspi_flash_device_type_s25flxxxl, "Wukong A100T"     },
  { 0xFE, 8, qspi_flash_device_type_none     , "Simulation"       },
  { 0x00, 0, qspi_flash_device_type_none     , NULL               }
};
// clang-format on

int8_t probe_hardware_version(void)
{
  uint8_t k;

  hw_model_id = PEEK(0xD629);
  for (k = 0; mega_models[k].name; k++)
    if (hw_model_id == mega_models[k].model_id)
      break;

  if (!mega_models[k].name)
    return -1;

  hw_model_name = mega_models[k].name;

  // we need to set those according to the hardware found
#ifdef STANDALONE
  SLOT_MB = mega_models[k].slot_mb;
  SLOT_SIZE_PAGES = SLOT_MB;
  SLOT_SIZE_PAGES <<= 12;
  SLOT_SIZE = SLOT_SIZE_PAGES;
  SLOT_SIZE <<= 8;
#endif

  switch (mega_models[k].qspi_flash_device_type)
  {
  case qspi_flash_device_type_s25flxxxl:
    qspi_flash_device = s25flxxxl;
    break;
  case qspi_flash_device_type_s25flxxxs:
    qspi_flash_device = s25flxxxs;
    break;
  default:
    qspi_flash_device = NULL;
  }

  return 0;
}

char *get_model_name(uint8_t model_id)
{
  static char *model_unknown = "?unknown?";
  uint8_t k;

  for (k = 0; mega_models[k].name; k++)
    if (model_id == mega_models[k].model_id)
      return mega_models[k].name;

  return model_unknown;
}

/***************************************************************************

 High-level flashing routines

 ***************************************************************************/

unsigned char j, k;

void flash_inspector(void)
{
#ifdef QSPI_FLASH_INSPECT
  addr = 0;

  while (1) {
    // read_data(addr);
    qspi_flash_read(qspi_flash_device, addr, data_buffer, 256);
    mhx_clearscreen(' ', MHX_A_WHITE);
    mhx_set_xy(0, 0);
    mhx_writef("Flash @ $%08lx:\n", addr);
    for (i = 0; i < 256; i++) {
      if (!(i & 15))
        mhx_writef("+%03x : ", i);
      mhx_writef("%02x", data_buffer[i]);
      if ((i & 15) == 15)
        mhx_writef("\n");
    }

    x = 0;
    while (!x) {
      x = PEEK(0xd610);
    }

    POKE(0xd610, 0);

    if (x) {
      switch (x) {
      case 0x13:
        addr = 0;
        break;
      case 0x51:
      case 0x71:
        addr -= 0x10000;
        break;
      case 0x41:
      case 0x61:
        addr += 0x10000;
        break;
      case 0x11:
      case 0x44:
      case 0x64:
        addr += 256;
        break;
      case 0x91:
      case 0x55:
      case 0x75:
        addr -= 256;
        break;
      case 0x1d:
      case 0x52:
      case 0x72:
        addr += 0x400000;
        break;
      case 0x9d:
      case 0x4c:
      case 0x6c:
        addr -= 0x400000;
        break;
      case 0x03:
        return;
#if 0
      case 0x50:
      case 0x70:
        query_flash_protection(addr);
        mhx_press_any_key(0, MHX_A_NOCOLOR);
        break;
      case 0x54:
      case 0x74:
        // T = Test
        // Erase page, write page, read it back
        erase_sector(addr);
        // Some known data
        for (i = 0; i < 256; i++) {
          data_buffer[i] = i;
          data_buffer[0x1ff - i] = i;
        }
        data_buffer[0] = addr >> 24L;
        data_buffer[1] = addr >> 16L;
        data_buffer[2] = addr >> 8L;
        data_buffer[3] = addr >> 0L;
        addr += 256;
        data_buffer[0x100] = addr >> 24L;
        data_buffer[0x101] = addr >> 16L;
        data_buffer[0x102] = addr >> 8L;
        data_buffer[0x103] = addr >> 0L;
        addr -= 256;
        //        lfill(0xFFD6E00,0xFF,0x200);
        mhx_writef("E: %02x %02x %02x\n", lpeek(0xffd6e00), lpeek(0xffd6e01), lpeek(0xffd6e02));
        mhx_writef("F: %02x %02x %02x\n", lpeek(0xffd6f00), lpeek(0xffd6f01), lpeek(0xffd6f02));
        mhx_writef("P: %02x %02x %02x\n", data_buffer[0], data_buffer[1], data_buffer[2]);
        // Now program it
        unprotect_flash(addr);
        query_flash_protection(addr);
        mhx_writef("About to call program_page()\n");
        //        program_page(addr,page_size);
        program_page(addr, 256);
        mhx_press_any_key(0, MHX_A_NOCOLOR);
#endif
      }
    }
  }
#endif
}

void reflash_slot_no_attic_ram(unsigned char the_slot, unsigned char selected_file, char *slot0version)
{
  char err;
  unsigned char slot = the_slot;
  unsigned long erase_block_size;
  unsigned int erase_block_size_in_pages;
  enum qspi_flash_page_size page_size;
  enum qspi_flash_erase_block_size max_erase_block_size;

  if (selected_file == MFS_FILE_INVALID)
  {
    return;
  }

  if (selected_file == MFS_FILE_ERASE && slot == 0)
  {
    // we refuse to erase slot 0
    mhx_writef(MHX_W_WHITE MHX_W_CLRHOME MHX_W_RED "\nRefusing to erase slot 0!\n\n" MHX_W_WHITE);
    mhx_press_any_key(0, MHX_A_NOCOLOR);
    return;
  }

  // Determine the page size.
  if (qspi_flash_get_page_size(qspi_flash_device, &page_size) != 0)
  {
    return;
  }

  // Determine the largest supported erase block size.
  if (get_max_erase_block_size(qspi_flash_device, &max_erase_block_size) != 0)
  {
    return;
  }

  // Determine erase block size in bytes.
  if (get_erase_block_size_in_bytes(max_erase_block_size, &erase_block_size) != 0)
  {
    return;
  }

  erase_block_size_in_pages = erase_block_size >> 8;

  mhx_clearscreen(' ', MHX_A_WHITE);
  mhx_writef(MHX_W_WHITE MHX_W_CLRHOME "\n\nReflashing slot %d...\n", slot);

  // progress_start(SLOT_SIZE_PAGES, "Erasing");
  for (addr = SLOT_SIZE * slot; addr < SLOT_SIZE * (slot + 1); addr += erase_block_size)
  {
    if ((err = qspi_flash_erase(qspi_flash_device, max_erase_block_size, addr)))
      break;
    POKE(0xD020, PEEK(0xD020) + 1);
    // progress_bar(erase_block_size_in_pages, "Erasing");
  }
  // progress_time(load_time);

  if (err)
  {
    mhx_set_xy(0, 10);
    mhx_writef(MHX_W_RED "ERROR: Could not erase sector at $%08lX (%d)!\n" MHX_W_WHITE, addr, err);
    mhx_press_any_key(0, MHX_A_WHITE);
    return;
  }

  if (selected_file == MFS_FILE_VALID)
  {
    // start flashing
    mhx_clearscreen(' ', MHX_A_WHITE);
    mhx_writef(MHX_W_WHITE MHX_W_CLRHOME "\n\nReflashing slot %d...\n", slot);

    if ((err = nhsd_open(mfsc_corefile_inode))) {
      // Couldn't open the file.
      mhx_writef(MHX_W_RED "\nERROR: Could not open core file (%d)!\n" MHX_W_WHITE, err);
      mhx_press_any_key(0, MHX_A_WHITE);
      return;
    }

    // progress_start(SLOT_SIZE_PAGES, "Flashing");
    for (addr = SLOT_SIZE * slot; addr < SLOT_SIZE * (slot + 1); addr += 512)
    {
      if (nhsd_read())
      {
        lfill((unsigned long)buffer, 0, 512);
      }
      else
      {
        lcopy(0xffd6e00L, (unsigned long)buffer, 512);
      }

      if ((err = qspi_flash_program(qspi_flash_device, page_size, addr, buffer)))
      {
        break;
      }

      if (page_size == qspi_flash_page_size_256)
      {
        if ((err = qspi_flash_program(qspi_flash_device, page_size, addr + 256UL, buffer + 256UL)))
        {
          break;
        }
      }

      if ((err = qspi_flash_verify(qspi_flash_device, addr, buffer, 512)))
      {
        break;
      }

      POKE(0xD020, PEEK(0xD020) + 1);
      // progress_bar(2, "Flashing");
    }
    // progress_time(flash_time);

    nhsd_close();

    if (err) {
      mhx_set_xy(0, 10);
      mhx_writef(MHX_W_RED "ERROR: Error during flashing of sector $%08lX (%d)!\n" MHX_W_WHITE, addr, err);
      mhx_press_any_key(0, MHX_A_WHITE);
      return;
    }

    // Undraw the sector display before showing results
    lfill(0x0400 + 12 * 40, 0x20, 512);
  }

  // EIGHT_FROM_TOP;
  mhx_writef("Flash slot successfully updated.\n\n");
  // if (load_time + flash_time > 0)
  //   mhx_writef("   Erase: %d sec \n"
  //              "   Flash: %d sec \n"
  //              "\n", load_time, flash_time);

  mhx_press_any_key(MHX_AK_ATTENTION, MHX_A_NOCOLOR);

  return;
}

/***************************************************************************

 Mid-level SPI flash routines

 ***************************************************************************/

unsigned char probe_qspi_flash(void)
{
  const char * manufacturer = NULL;
  unsigned int size;
  enum qspi_flash_page_size page_size;
  unsigned int page_size_bytes;
  BOOL erase_block_sizes[qspi_flash_erase_block_size_last];

  mhx_writef("\nHardware model = %s\n\n", hw_model_name);

  mhx_writef("Probing flash...");

  if (qspi_flash_init(qspi_flash_device))
  {
    mhx_writef(MHX_W_RED " ERROR" MHX_W_WHITE "\n\n");
    return -1;
  }
  mhx_writef(" OK\n\n");

  if (qspi_flash_get_manufacturer(qspi_flash_device, &manufacturer) != 0)
  {
    return -1;
  }

  if (qspi_flash_get_size(qspi_flash_device, &size) != 0)
  {
    return -1;
  }

  if (qspi_flash_get_page_size(qspi_flash_device, &page_size) != 0)
  {
    return -1;
  }

  if (get_page_size_in_bytes(page_size, &page_size_bytes) != 0)
  {
    return -1;
  }

  for (i = 0; i < qspi_flash_erase_block_size_last; ++i)
  {
    if (qspi_flash_get_erase_block_size_support(qspi_flash_device, (enum qspi_flash_erase_block_size) i, &erase_block_sizes[i]) != 0)
    {
      return -1;
    }
  }

  slot_count = size / SLOT_MB;

  mhx_writef("Manufacturer = %S\n"
             "Flash size   = %u MB\n"
             "Flash slots  = %u x %u MB\n",
             manufacturer, size, (unsigned int) slot_count, (unsigned int) SLOT_MB);
  mhx_writef("Erase sizes  =");
  if (erase_block_sizes[qspi_flash_erase_block_size_4k])
    mhx_writef(" 4K");
  if (erase_block_sizes[qspi_flash_erase_block_size_32k])
    mhx_writef(" 32K");
  if (erase_block_sizes[qspi_flash_erase_block_size_64k])
    mhx_writef(" 64K");
  if (erase_block_sizes[qspi_flash_erase_block_size_256k])
    mhx_writef(" 256K");
  mhx_writef("\n");
  mhx_writef("Page size    = %u\n", page_size_bytes);
  mhx_writef("\n");
  mhx_press_any_key(0, MHX_A_NOCOLOR);

  return 0;
}
