#ifndef QSPIHWASSIST_H
#define QSPIHWASSIST_H

void hw_assisted_read_512(unsigned long address, unsigned char * data);
void hw_assisted_erase_sector(unsigned long address);
void hw_assisted_program_page_512(unsigned long address, const unsigned char * data);
void hw_assisted_program_page_256(unsigned long address, const unsigned char * data);

// TODO: Function to erase a sector using SPI command 0xdc; POKE 0x58 to $D680.

// TODO: Function to erase a sector using SPI command 0x21; POKE 0x59 to $D680.

// TODO: Function to verify in place; POKE 0x56 to $D680.

// TODO: Function to set number of dummy cycles; POKE 0x5a .. 0x5f to $D680.

// TODO: Function to set write enable using SPI command 0x06; POKE 0x66 to $D680.

// TODO: Function to clear status register using SPI command 0x30; POKE 0x6a to $D680.

void hw_assisted_cfi_block_read(unsigned char * data);

#endif /* QSPIHWASSIST_H */
