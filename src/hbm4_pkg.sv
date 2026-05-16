`ifndef HBM4_PKG_SV
`define HBM4_PKG_SV

package hbm4_pkg;

  // HBM4 Constants
  localparam int NUM_CHANNELS = 32;
  localparam int PC_PER_CH    = 2; // Pseudo Channels per Channel
  
  // DQ Width per Pseudo Channel is 32 bits
  localparam int DQ_WIDTH_PC = 32;
  localparam int DQ_WIDTH_CH = DQ_WIDTH_PC * PC_PER_CH; // 64 bits

  // Addressing params (can vary, assuming 16Gb density per channel)
  localparam int BA_WIDTH  = 4; // 16 Banks
  localparam int BG_WIDTH  = 2; // 4 Bank Groups
  localparam int ROW_WIDTH = 15;
  localparam int COL_WIDTH = 6; 

  // Commands based on JESD270-4
  typedef enum logic [3:0] {
    CMD_NOP = 4'b0000,
    CMD_ACT = 4'b0001,
    CMD_PRE = 4'b0010,
    CMD_RD  = 4'b0011,
    CMD_WR  = 4'b0100,
    CMD_MRS = 4'b0101,
    CMD_REF = 4'b0110,
    CMD_SRE = 4'b0111,
    CMD_PDE = 4'b1000,
    CMD_PREA  = 4'b1001,
    CMD_REFpb = 4'b1010,
    CMD_MRR   = 4'b1011,
    CMD_PDX   = 4'b1100,
    CMD_SRX   = 4'b1101,
    CMD_ZQ    = 4'b1110,
    CMD_RFM   = 4'b1111  // Refresh Management (BA[3]: 0=RFMab, 1=RFMpb)
  } hbm4_cmd_e;

  // AWORD (Row Command Bus) Structure
  typedef struct packed {
    logic       R;      // Reserved / Parity
    logic [4:0] R_ADDR; // Row Address portions
    logic [3:0] BA;     // Bank Address
    logic [1:0] BG;     // Bank Group
    logic [3:0] CMD;    // Command
  } aword_t;

  // DWORD (Column Command Bus) Structure
  typedef struct packed {
    logic       C;      // Reserved / Parity
    logic [5:0] C_ADDR; // Column Address
    logic [3:0] BA;     // Bank Address
    logic [1:0] BG;     // Bank Group
    logic [3:0] CMD;    // Command
  } dword_t;

  // Timing Parameters (Based on Micron HBM3E Datasheet RevL)
  // Assuming nominal tCK = 1ns for nCK to ns conversion
  localparam time tRCDRD = 17ns;  // ACT to READ delay
  localparam time tRCDWR = 15ns;  // ACT to WRITE delay
  localparam time tRCD   = 17ns;  // Legacy alias (max of RD/WR)
  localparam time tCL  = 10ns;
  localparam time tWL  = 8ns;
  localparam time tRP  = 16ns;
  localparam time tRAS = 30ns;
  localparam time tRC  = 46ns; // tRAS + tRP
  localparam time tFAW   = 16ns; // Four Activate Window
  localparam time tRRD_L = 6ns;  // Row-to-Row Delay (Same BG)
  localparam time tRRD_S = 4ns;  // Row-to-Row Delay (Diff BG)

  // Advanced Timing Parameters
  localparam time tCCD_L = 4ns;  // 4 nCK
  localparam time tCCD_S = 2ns;  // 2 nCK
  localparam time tWTR_L = 8ns;  // 4*tCK + 4ns
  localparam time tWTR_S = 6ns;  // 2*tCK + 4ns
  localparam time tRTW   = 18ns; // 18 nCK
  localparam time tWR    = 20ns; // Write recovery
  localparam time tRTP_L = 5ns;  // Read-to-Precharge (same bank group)
  localparam time tRTP_S = 4ns;  // Read-to-Precharge (diff bank group)
  localparam time tRTP   = 4ns;  // Legacy alias (minimum)

  // Refresh & MRS Parameters
  // Refresh Timings
  localparam time tRFC   = 260ns;
  localparam time tRFCpb = 130ns; // Per-Bank Refresh Cycle Time
  localparam time tREFI  = 3900ns; // 3.9us
  localparam time tREFW  = 32000ns; // 32us Per-Bank Refresh Window
  localparam time tRREFD = 8ns;   // REF-to-REF delay (different bank groups)
  localparam time tMOD   = 10ns;   // MRS update delay
  localparam time tMRD   = 10ns;   // MRS to MRS delay

  // Low-Power State Timings
  localparam time tPD    = 10ns;   // Power-Down minimum time
  localparam time tXP    = 8ns;    // Power-Down Exit Time
  localparam time tXS    = 200ns;  // Self-Refresh Exit Delay
  localparam time tCKSRE = 10ns;   // Valid clock after Self-Refresh Entry
  localparam time tCPDED = 4ns;    // Command-to-Power-Down Entry Delay
  localparam time tWRPDE = 28ns;   // Write Recovery + PDE delay (tWR + tCK margin)
  localparam time tXSMRS = 210ns;  // Self-Refresh Exit to MRS delay

  // ZQ Calibration Timings
  localparam time tZQCS  = 128ns;  // ZQ Calibration Short
  localparam time tZQCL  = 256ns;  // ZQ Calibration Long

  // Auto-Precharge
  localparam int AP_BIT = 5;       // C_ADDR bit that signals auto-precharge

  // Refresh Management (RFM) Timings
  localparam time tRFM = 260ns;    // RFM cycle time (same as tRFC for all-bank)
  localparam time tRFMpb = 130ns;  // Per-bank RFM cycle time

  // Directed Refresh Management (DRFM)
  localparam int  DRFM_BIT = 4;    // R_ADDR bit that signals DRFM on ACT command
  localparam time tDRFM = 260ns;   // DRFM cycle time

  // AC DBI Toggle Calculation Function
  function automatic logic [8:0] compute_dbi_byte(input logic [7:0] data, input logic [7:0] prev_data, input logic prev_dbi);
    int toggle_count = $countones(data ^ prev_data);
    if (toggle_count > 4 || (toggle_count == 4 && prev_dbi == 1)) begin
      return {1'b1, ~data}; // {DBI, Inverted_Data}
    end else begin
      return {1'b0, data};  // {DBI, Original_Data}
    end
  endfunction

  function automatic logic [35:0] process_dbi_word(input logic [31:0] data, input logic [35:0] last_state, input logic en);
    logic [35:0] res;
    logic [8:0] b_res0, b_res1, b_res2, b_res3;
    if (en) begin
      b_res0 = compute_dbi_byte(data[7:0],   last_state[7:0],   last_state[32]);
      b_res1 = compute_dbi_byte(data[15:8],  last_state[15:8],  last_state[33]);
      b_res2 = compute_dbi_byte(data[23:16], last_state[23:16], last_state[34]);
      b_res3 = compute_dbi_byte(data[31:24], last_state[31:24], last_state[35]);
      res[7:0]   = b_res0[7:0];
      res[32]    = b_res0[8];
      res[15:8]  = b_res1[7:0];
      res[33]    = b_res1[8];
      res[23:16] = b_res2[7:0];
      res[34]    = b_res2[8];
      res[31:24] = b_res3[7:0];
      res[35]    = b_res3[8];
    end else begin
      res[31:0]  = data[31:0];
      res[35:32] = 4'b0000;
    end
    return res;
  endfunction

endpackage : hbm4_pkg

`endif
