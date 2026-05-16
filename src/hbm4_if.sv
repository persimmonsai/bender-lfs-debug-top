`ifndef HBM4_IF_SV
`define HBM4_IF_SV

import hbm4_pkg::*;

interface hbm4_if (
  input logic CK_t,
  input logic CK_c,
  input logic WCK_t,
  input logic WCK_c,
  input logic RESET_n
);

  // Global signals (per channel)
  logic CKE;
  logic AERR; // Address/Command Parity Error
  logic DERR; // Data Error / ECC Error
  logic CATTRIP; // Catastrophic Temperature Trip

  // AWORD (Row Command/Address)
  logic [15:0] AWORD;

  // DWORD (Column Command/Address)
  // Actually, JESD270-4 has DWORD split or multiplexed, let's represent it simply for simulation.
  // There is a DWORD for PC0 and a DWORD for PC1.
  logic [16:0] DWORD_PC0;
  logic [16:0] DWORD_PC1;

  // Data Strobes
  // WDQS for write data, RDQS for read data
  // One differential pair per 32-bit DWORD (so 1 pair per PC for 32-bit, or 2 pairs per PC?)
  // Let's assume 1 pair per PC (32 DQ bits).
  logic WDQS_t_PC0, WDQS_c_PC0;
  logic WDQS_t_PC1, WDQS_c_PC1;
  logic RDQS_t_PC0, RDQS_c_PC0;
  logic RDQS_t_PC1, RDQS_c_PC1;

  // Data Bus (64 bits total, 32 per PC)
  wire [DQ_WIDTH_PC-1:0] DQ_PC0;
  wire [DQ_WIDTH_PC-1:0] DQ_PC1;

  // Data Bus Inversion (4 bits per PC, 1 bit per byte)
  wire [3:0] DBI_PC0;
  wire [3:0] DBI_PC1;

  // IEEE 1500 Test Port Pins
  logic WRCK;
  logic WRST_n;
  logic WSI;
  logic WSO;
  logic SHIFTWR;
  logic UPDATEWR;
  logic CAPTUREWR;
  logic SELECTWIR;

  // Modport for the Memory Model
  modport mem (
    input  CK_t, CK_c, WCK_t, WCK_c, RESET_n, CKE,
    input  AWORD,
    input  DWORD_PC0, DWORD_PC1,
    input  WDQS_t_PC0, WDQS_c_PC0, WDQS_t_PC1, WDQS_c_PC1,
    output RDQS_t_PC0, RDQS_c_PC0, RDQS_t_PC1, RDQS_c_PC1,
    inout  DQ_PC0, DQ_PC1, DBI_PC0, DBI_PC1,
    output AERR,
    output DERR,
    output CATTRIP,
    input  WRCK, WRST_n, WSI, SHIFTWR, UPDATEWR, CAPTUREWR, SELECTWIR,
    output WSO
  );

  // Modport for the Controller / BFM
  modport ctrl (
    input  CK_t, CK_c, WCK_t, WCK_c, RESET_n,
    output CKE,
    output AWORD,
    output DWORD_PC0, DWORD_PC1,
    output WDQS_t_PC0, WDQS_c_PC0, WDQS_t_PC1, WDQS_c_PC1,
    input  RDQS_t_PC0, RDQS_c_PC0, RDQS_t_PC1, RDQS_c_PC1,
    inout  DQ_PC0, DQ_PC1, DBI_PC0, DBI_PC1,
    input  AERR,
    input  DERR,
    input  CATTRIP,
    output WRCK, WRST_n, WSI, SHIFTWR, UPDATEWR, CAPTUREWR, SELECTWIR,
    input  WSO
  );

endinterface : hbm4_if

`endif
