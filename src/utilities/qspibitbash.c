#include <memory.h>

#include "qspibitbash.h"

/*
  $D6CC.0 = data bit 0 / SI (serial input)
  $D6CC.1 = data bit 1 / SO (serial output)
  $D6CC.2 = data bit 2 / WP# (write protect)
  $D6CC.3 = data bit 3 / HOLD#
  $D6CC.4 = tri-state SI only (to enable single bit SPI communications) -> NOT CONNECTED!
  $D6CC.5 = clock -> NOT CONNECTED!
  $D6CC.6 = CS#
  $D6CC.7 = data bits DDR (all 4 bits at once) -> #OE ('0' means output enabled)
*/
#define BITBASH_PORT 0xD6CCU

/*
  $D6CD.0 = clock free run if set, or under bitbash control when 0
  $D6CD.1 = alternate control of clock pin
*/
#define CLOCKCTL_PORT 0xD6CDU

#if 0
// TODO: replace this with a macro that calls usleep instead or does nothing
static void delay(void)
{
  // Slow down signalling when debugging using JTAG monitoring.
  // Not needed for normal operation.

  // unsigned int di;
  //   for(di=0;di<1000;di++) continue;
}

unsigned char bash_bits = 0xFF;

void spi_tristate_si(void)
{
  POKE(BITBASH_PORT, 0x8f);
  bash_bits |= 0x8f;
}

void spi_tristate_si_and_so(void)
{
  POKE(BITBASH_PORT, 0x8f);
  bash_bits |= 0x8f;
}

unsigned char spi_sample_si(void)
{
  bash_bits |= 0x80;
  POKE(BITBASH_PORT, 0x80);
  if (PEEK(BITBASH_PORT) & 0x02)
    return 1;
  else
    return 0;
}

void spi_so_set(unsigned char b)
{
  // De-tri-state SO data line, and set value
  bash_bits &= (0x7f - 0x01);
  bash_bits |= (0x0F - 0x01);
  if (b)
    bash_bits |= 0x01;
  POKE(BITBASH_PORT, bash_bits);
  DEBUG_BITBASH(bash_bits);
}

void qspi_nybl_set(unsigned char nybl)
{
  // De-tri-state SO data line, and set value
  bash_bits &= 0x60;
  bash_bits |= (nybl & 0xf);
  POKE(BITBASH_PORT, bash_bits);
  DEBUG_BITBASH(bash_bits);
}
#endif

// unsigned char spi_transaction(unsigned char byte) {
//     spi_clock_high();
//     spi_cs_low();
//     spi_output_enable();
//     spi_tx_byte(tx_bytes[i]);
//     spi_output_disable();
//     for (unsigned char i = 0; i < num_rx; ++i)
//         rx_bytes[i] = spi_rx_byte();
//     spi_cs_high();
//     spi_clock_high();
// }

void spi_transaction(const unsigned char *tx_bytes, unsigned char num_tx,
                     unsigned char *rx_bytes, unsigned char num_rx) {
    unsigned char i;
    spi_clock_high();
    spi_cs_low();
    spi_output_enable();
    for (i = 0; i < num_tx; ++i)
        spi_tx_byte(tx_bytes[i]);
    spi_output_disable();
    for (i = 0; i < num_rx; ++i)
        rx_bytes[i] = spi_rx_byte();
    spi_cs_high();
    spi_clock_high();
}

void spi_transaction_tx8(unsigned char tx_byte) {
    spi_clock_high();
    spi_cs_low();
    spi_output_enable();
    spi_tx_byte(tx_byte);
    spi_output_disable();
    spi_cs_high();
    spi_clock_high();
}

unsigned char spi_transaction_tx8rx8(unsigned char tx_byte) {
    unsigned char rx_byte;
    spi_clock_high();
    spi_cs_low();
    spi_output_enable();
    spi_tx_byte(tx_byte);
    spi_output_disable();
    rx_byte = spi_rx_byte();
    spi_cs_high();
    spi_clock_high();
    return rx_byte;
}

unsigned char spi_rx_byte(void) {
    unsigned char i;
    unsigned char byte = 0;

    for (i = 0; i < 8; i++) {
        byte <<= 1;
        spi_clock_low();
        if (PEEK(BITBASH_PORT) & 0x02)
            byte |= 0x01;
        spi_clock_high();
    }

    return byte;
}

unsigned char qspi_rx_byte(void) {
    unsigned char byte = 0;

    spi_clock_low();
    byte |= PEEK(BITBASH_PORT) & 0x0f;
    spi_clock_high();

    byte <<= 4;

    spi_clock_low();
    byte |= PEEK(BITBASH_PORT) & 0x0f;
    spi_clock_high();

    return byte;
}

void spi_tx_byte(unsigned char byte) {
    unsigned char i;
    unsigned char port_value;

    port_value = PEEK(BITBASH_PORT) & 0xf0;
    for (i = 0; i < 8; i++) {
        spi_clock_low();
        POKE(BITBASH_PORT, port_value | ((byte & 0x80) ? 0x0f : 0x0e));
        spi_clock_high();
        byte <<= 1;
    }
}

void qspi_tx_byte(unsigned char byte) {
    unsigned char port_value;

    port_value = PEEK(BITBASH_PORT) & 0xf0;
    spi_clock_low();
    POKE(BITBASH_PORT, port_value | ((byte & 0xf0) >> 4));
    spi_clock_high();
    spi_clock_low();
    POKE(BITBASH_PORT, port_value | (byte & 0x0f));
    spi_clock_high();
}

void spi_idle_clocks(unsigned char count) {
    for (; count > 0; --count) {
        spi_clock_low();
        spi_clock_high();
    }
}

void spi_output_enable(void) {
    POKE(BITBASH_PORT, PEEK(BITBASH_PORT) & 0x7f);
}

void spi_output_disable(void) {
    POKE(BITBASH_PORT, PEEK(BITBASH_PORT) | 0x80);
}

void spi_cs_low(void) {
    POKE(BITBASH_PORT, PEEK(BITBASH_PORT) & 0xbf);
}

void spi_cs_high(void) {
    POKE(BITBASH_PORT, PEEK(BITBASH_PORT) | 0x40);
}

void spi_clock_low(void) {
    POKE(CLOCKCTL_PORT, 0x00);
}

void spi_clock_high(void) {
    POKE(CLOCKCTL_PORT, 0x02);
}

#if 0
void spi_tx_bit(unsigned char bit)
{
  spi_clock_low();
  spi_so_set(bit);
  spi_clock_high();
}

void qspi_tx_nybl(unsigned char nybl)
{
  qspi_nybl_set(nybl);
  spi_clock_low();
  delay();
  spi_clock_high();
  delay();
}

void qspi_tx_byte(unsigned char b)
{
  qspi_tx_nybl((b & 0xf0) >> 4);
  qspi_tx_nybl(b & 0xf);
}

unsigned char qspi_rx_byte(void)
{
  unsigned char b;

  spi_tristate_si_and_so();

  spi_clock_low();
  b = PEEK(BITBASH_PORT) & 0x0f;
  spi_clock_high();

  spi_clock_low();
  b = b << 4;
  b |= PEEK(BITBASH_PORT) & 0x0f;
  spi_clock_high();

  return b;
}
#endif
