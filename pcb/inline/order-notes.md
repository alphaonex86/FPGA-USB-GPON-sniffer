## Before use

- Flash (U9): JLC places the DIP-8 socket only. Buy a W25Q32 in DIP-8 (W25Q32JVDAIQ, or any 3.3 V SPI NOR flash of
  32 Mbit or more in DIP-8), write `out/artix7/inline.bin` into it in a programmer (CH341A:
  `flashrom -p ch341a_spi -w out/artix7/inline.bin`) and insert it, notch on the socket's notch.
- JTAG (J2): not fitted, its pads stay for rescue (1 +3V3, 2 TCK, 3 TDI, 4 TDO, 5 TMS, 6 GND): a Xilinx Platform
  Cable USB (or its clone) with Vivado or `openFPGALoader -c xilinxPlatformCableUsb out/artix7/inline.bit`.
- R76: not fitted. It is the upstream offset resistor's other place: if the ONU-port BOSA gives its data inverted,
  R75's 5.1 k moves there (and `onu_rx_inverted = 1` goes in the level file).
- BOSAs (U10 OLT port: GPON ONU type, 1310 nm DFB + 1490 nm APD-TIA; U19 ONU port: GPON OLT type, 1490 nm DFB +
  1310 nm burst APD-TIA): JLCPCB cannot supply one (not in its library, not at DigiKey / Mouser): soldered by hand.
  U10 is taken from an ONU (HSGQ X100DG, X111W): the land is theirs, so it goes in as it sat there. U19 is the
  XL-BCB2111-LS-02 (Shenzhen Starsealand): its approval sheet's pin drawing agrees with the table below lead for lead.
  Mounting: the RX can's five leads straight down into A-E, the fibre pointing into the board (west) above the low
  parts; the TX can lies on the fibre's axis at the east end, its four leads bent down: the case lead (the one on the
  RX leads' side) is the shortest bend, into T4; PD+ (opposite) the longest, into T2; LD+ / PD- into T1 (B's side),
  LD- into T3. Another maker turns the cans in the body to order: buy against this table (the letters are on the
  silkscreen; seen from above, RX can on the left) and ask for the pin drawing first.
  To ask Starsealand: is "Isource" the APD bias lead (the sheet gives Vbr 33-60 V and no other lead for it); is the
  TIA a burst-mode one; its overload level; SC/UPC (the title) or SC/APC (the drawing).

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
- Shield cans, one per receiver: 0.2 mm tinplate, folded by hand, pushed into the three clips around each limiting
  amplifier (SH1-SH3, SH4-SH6). Lid 11.8 mm wide (between the side clips) and about 9.3 mm long: from the north clip
  to the BOSA body, trimmed to touch it; walls on the north, west and east sides only, 3 mm high. The south side
  stays open: the receive pair runs there on the board to the RX can's leads, under the BOSA's metal body. The can
  covers the top side only; on the bottom the lead ends are bare. No foreign track within 2 mm of the leads on either side.
- Power: about 2.3 W from USB: a USB-C or USB 3 host port.
- No light without the host tool: it sets the APD bias and the laser currents (both DACs power up at 0 V).
