## Before use

- Flash (U9): JLC places the DIP-8 socket only. Buy a W25Q32 in DIP-8 (W25Q32JVDAIQ, or any 3.3 V SPI NOR flash of
  32 Mbit or more in DIP-8), write `out/artix7/inline.bin` into it in a programmer (CH341A:
  `flashrom -p ch341a_spi -w out/artix7/inline.bin`) and insert it, notch on the socket's notch.
- JTAG (J2): not fitted, its pads stay for rescue (1 +3V3, 2 TCK, 3 TDI, 4 TDO, 5 TMS, 6 GND): a Xilinx Platform
  Cable USB (or its clone) with Vivado or `openFPGALoader -c xilinxPlatformCableUsb out/artix7/inline.bit`.
- BOSAs (U10 OLT port: GPON ONU type, 1310 nm DFB + 1490 nm APD-TIA; U19 ONU port: GPON OLT type, 1490 nm DFB +
  1310 nm burst APD-TIA): no distributor JLCPCB buys from sells one (not in its library, not at DigiKey / Mouser):
  bought from the maker and soldered by hand, or sent to JLCPCB as consigned parts. The land is the HSGQ X100DG's
  (both TO cans under the body). Every maker turns the cans in the body to order, so buy against this table (the
  letters are on the silkscreen; seen from above, RX can on the left) and ask for the pin drawing first:

  | Lead | RX can (TO-46, 5 leads)                         | Lead | TX can (TO-56, 4 leads)                  |
  |------|--------------------------------------------------|------|-------------------------------------------|
  | B    | GND, case (the middle one of the 3 close leads)  | T4   | case (toward the RX can), on GND          |
  | A    | OUT+ (left of B)                                 | T1   | laser anode + monitor cathode (B's side)  |
  | C    | OUT- (right of B)                                | T2   | monitor anode (away from the RX can)      |
  | D    | VCC 3.3 V (under A)                              | T3   | laser cathode (D / E's side)              |
  | E    | APD bias, up to 55 V (under C)                   |      |                                           |

  Seen from the leads, as datasheets draw it: GND, OUT-, APD, VCC, OUT+ counter-clockwise; case, LD+ / PD-, PD+, LD-
  counter-clockwise. A can whose case is the laser anode does not fit (T4 is on GND).
- First power-up of each BOSA, before the APD bias is switched on (LASERS.apd): the APD current reads zero. A reading
  of milliamps means VCC and APD are exchanged on that part (the TIA is drawing through the APD lead): stop there.
- Shield cans: 0.2 mm tinplate, folded by hand, pushed into the clips (SH1-SH6) over each limiting amplifier.
- Power: about 2.3 W from USB: a USB-C or USB 3 host port.
- No light without the host tool: it sets the APD bias and the laser currents (both DACs power up at 0 V).
