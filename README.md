# MEGA65 fork for the QMTech Wukong board with DDR3-based attic RAM

This is a community fork of the [MEGA65 project](https://github.com/MEGA65/mega65-core)
for the QMTech Wukong Board. The DDR3 SDRAM chip on the board is made available
as attic RAM for the MEGA65 using the
[UberDDR3](https://github.com/AngeloJacobo/UberDDR3) open-source DDR3 controller.

You will optionally need the a MEGA65 ROM file, if you wish to use BASIC65:
https://files.mega65.org?id=54e69439-f25e-4124-8c78-22ea7ddc0f1c

If you do not have such a file, the MEGA65 contains the free and open-source
OpenROM alternative.

**Important:** There are several different revisions of the QMTech Wukong board,
which have different on-board connectors that are connected to different pins
of the FPGA. This fork is specific to the second revision (V2) board. Do not try
to use a bitstream built using this fork on other revisions as this may damage
the board.

**License note:** This fork includes GPLv3-licensed files from UberDDR3. As a
result, this combined work is distributed under the **GNU General Public License v3 (GPLv3)**.
The original MEGA65 sources remain under LGPLv3. Due to this license difference,
the DDR3 SDRAM related changes cannot be merged back into the upstream MEGA65
project.
