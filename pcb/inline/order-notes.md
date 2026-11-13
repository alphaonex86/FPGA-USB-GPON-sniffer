## Before use

- Flash (U9): JLC places the DIP-8 socket only. Buy a W25Q32 in DIP-8 (W25Q32JVDAIQ, or any 3.3 V SPI NOR flash of
  32 Mbit or more in DIP-8), write `out/artix7/inline.bin` into it in a programmer (CH341A:
  `flashrom -p ch341a_spi -w out/artix7/inline.bin`) and insert it, notch on the socket's notch.
- JTAG (J2): not fitted, its pads stay for rescue (1 +3V3, 2 TCK, 3 TDI, 4 TDO, 5 TMS, 6 GND): a Xilinx Platform
  Cable USB (or its clone) with Vivado or `openFPGALoader -c xilinxPlatformCableUsb out/artix7/inline.bit`.
- BOSAs (U10 OLT port, U19 ONU port): not in JLC's library, soldered by hand. The land is the X100DG's, measured on
  a stripped board; check the lead functions (`common/pcb/gen/bosa.py`) on the part before soldering it.
- Shield cans: 0.2 mm tinplate, folded by hand, pushed into the clips (SH1-SH6) over each limiting amplifier.
- Power: about 2.3 W from USB: a USB-C or USB 3 host port.
- No light without the host tool: it sets the APD bias and the laser currents (both DACs power up at 0 V).
