#ifndef QSPICOMMON_H
#define QSPICOMMON_H
/*
 * QSPI tools that are used to flash the QSPI,
 * used in: MEGAFLASH and derivates
 */

/*
 * Compile time options:
 *
 * Hardware releated:
 *   STANDALONE         - build standalone version instead of CORE-integrated version
 *                        sets slot size based on detected hardware
 *   A100T              - FPGA model A100T with 4MB slot size
 *                        sets slot size to 4MB
 *                        sets TAB_FOR_MENU
 *   A200T              - FPGA model A200T with 8MB slot size
 *                        sets slot size to 8MB
 *   TAB_FOR_MENU       - allow TAB key to enter MENU (default: NO SCROLL only)
 *
 * QSPI Verbosity & Debugging:
 *   QSPI_VERBOSE       - more verbose QSPI probing output (not inteded for CORE inclusion)
 *   QSPI_DEBUG         - even more output and debug testing (implies QSPI_VERBOSE)
 *
 * QSPI Options:
 *   QSPI_FLASH_SLOT0   - allow flashing of slot 0
 *   QSPI_ERASE_ZERO    - allow erasing of slot 0
 *   QSPI_FLASH_INSPECT - enable flash inspector tool
 *   FIRMWARE_UPGRADE   - this removes file selection from slot 0 flashing,
 *                        just uses UPGRADE0.COR instead
 *
 * Control scheme:
 *   WITH_JOYSTICK      - enable joystick navigation in file selector
 *
 */

#include <stdint.h>

#ifdef QSPI_DEBUG
#ifndef QSPI_VERBOSE
#define QSPI_VERBOSE 1
#endif
#endif

#if (defined(A100T) && defined(A200T)) || (defined(A100T) && defined(STANDALONE)) || (defined(STANDALONE) && defined(A200T))
#error A100T, A200T, and STANDALONE defines are exclusive!
#endif

#if defined(A100T)
#define TAB_FOR_MENU 1
#define SLOT_SIZE (4L * 1048576L)
#define SLOT_SIZE_PAGES (4L * 4096L)
#define SLOT_MB 4
#elif defined(A200T)
#define SLOT_MB 8
#define SLOT_SIZE (8L * 1048576L)
#define SLOT_SIZE_PAGES (8L * 4096L)
#elif defined(STANDALONE)
extern uint8_t SLOT_MB;
extern unsigned long SLOT_SIZE;
extern unsigned long SLOT_SIZE_PAGES;
#else
#error Please defined one of A100T, A200T, or STANDALONE
#endif

enum qspi_flash_device_type {
  qspi_flash_device_type_none,
  qspi_flash_device_type_s25flxxxs,
  qspi_flash_device_type_s25flxxxl
};

typedef struct {
  int model_id;
  uint8_t slot_mb;
  enum qspi_flash_device_type qspi_flash_device_type;
  char *name;
} models_type;

extern models_type mega_models[];

extern uint8_t hw_model_id;
extern char *hw_model_name;
extern unsigned char slot_count;

extern void * qspi_flash_device;

extern unsigned char bash_bits;
extern unsigned int page_size;
extern unsigned char latency_code;
extern unsigned char reg_cr1;
extern unsigned char reg_sr1;
extern unsigned char reg_ppbl;
extern unsigned char reg_ppb;

extern unsigned char verboseProgram;

extern unsigned char manufacturer;
extern unsigned short device_id;
extern unsigned char cfi_data[512];
extern unsigned short cfi_length;
extern unsigned char flash_sector_bits;
extern unsigned char last_sector_num;
extern unsigned char sector_num;

extern unsigned char data_buffer[512];

extern unsigned short mb;

extern unsigned char buffer[512];
extern unsigned char part[256];

extern short i, x, y, z;
extern unsigned long addr, addr_len;

int8_t probe_hardware_version(void);
char *get_model_name(uint8_t model_id);
unsigned char probe_qspi_flash(void);
void reflash_slot_no_attic_ram(unsigned char the_slot, unsigned char selected_file, char *slot0version);
void flash_inspector(void);

#endif /* QSPICOMMON_H */
