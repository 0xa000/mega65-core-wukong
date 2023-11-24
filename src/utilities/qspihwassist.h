#ifndef QSPIHWASSIST_H
#define QSPIHWASSIST_H

void hw_assisted_read_512(unsigned long address, unsigned char * data);
void hw_assisted_program_page_512(unsigned long address, const unsigned char * data);
void hw_assisted_program_page_256(unsigned long address, const unsigned char * data);
// char verify_data_in_place(unsigned long start_address);

// void hw_assisted_erase_sector_0xDC?(unsigned long address);

// TODO: Function to set dummy cycles... POKE to $D680

// void erase_sector_0x21?(unsigned long address);

// TODO: Function to set write enable (0x06), POKE 0x66 to $D680.

// TODO: Function to clear status register (0x30), POKE 0x6a to $D680.

void hw_assisted_cfi_block_read(unsigned char * data);

#endif /* QSPIHWASSIST_H */
