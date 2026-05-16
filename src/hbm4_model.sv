`ifndef HBM4_MODEL_SV
`define HBM4_MODEL_SV

import hbm4_pkg::*;

module hbm4_model (
  hbm4_if.mem vif
);

  // Define Bank States
  typedef enum logic [1:0] {
    BANK_IDLE,
    BANK_ACTIVE
  } bank_state_e;

  // Total banks = 2^(BA_WIDTH + BG_WIDTH)
  localparam int NUM_BANKS = 1 << (BA_WIDTH + BG_WIDTH);

  // Bank state tracking
  bank_state_e bank_state [NUM_BANKS];
  logic [ROW_WIDTH-1:0] active_row [NUM_BANKS];

  // Memory Arrays for PC0 and PC1 (BL=8 -> 256 bits per burst)
  // Address structure: {bg[1:0], ba[3:0], row[14:0], col[5:0]}
  logic [255:0] mem_array_pc0 [int];
  logic [255:0] mem_array_pc1 [int];

  // ECC Check Bit Storage (parallel to memory arrays)
  logic [ECC_CHECK_BITS-1:0] ecc_array_pc0 [int];
  logic [ECC_CHECK_BITS-1:0] ecc_array_pc1 [int];

  // ECC statistics counters
  int ecc_sec_count = 0; // Single-bit errors corrected
  int ecc_ded_count = 0; // Double-bit errors detected
  int timing_violation_count = 0; // Incremented on each timing error

  // Interconnect Redundancy Remap Table
  // Per JESD270-4 §7.11: programmable via IEEE 1500 WSP (WIR=8'h02)
  // Each entry maps a faulty row address to a spare row
  localparam int REMAP_TABLE_SIZE = 16;
  typedef struct packed {
    logic        valid;
    logic [1:0]  bg;      // bank group
    logic [3:0]  ba;      // bank address
    logic [ROW_WIDTH-1:0] faulty_row;
    logic [ROW_WIDTH-1:0] spare_row;
  } remap_entry_t;
  remap_entry_t remap_table [REMAP_TABLE_SIZE];
  int remap_count = 0;

  // Remap address translation — returns remapped row or original if no match
  function automatic logic [ROW_WIDTH-1:0] remap_row(
    input logic [1:0] bg, input logic [3:0] ba, input logic [ROW_WIDTH-1:0] row
  );
    for (int i = 0; i < remap_count; i++) begin
      if (remap_table[i].valid && remap_table[i].bg == bg &&
          remap_table[i].ba == ba && remap_table[i].faulty_row == row) begin
        $display("[%0t] HBM4_REMAP: Redirecting BG%0d BA%0d Row 0x%04h -> Spare 0x%04h",
                 $time, bg, ba, row, remap_table[i].spare_row);
        return remap_table[i].spare_row;
      end
    end
    return row;
  endfunction

  // Timing Trackers
  time last_act_time [NUM_BANKS];
  time last_pre_time [NUM_BANKS];
  time last_bank_wr_time [NUM_BANKS];
  time last_bank_rd_time [NUM_BANKS];
  time act_history [4];
  time last_global_act_time = 0;
  logic [1:0] last_act_bg = 0;

  // Global PC Trackers
  time last_rd_time_pc0 = 0, last_wr_time_pc0 = 0;
  logic [1:0] last_rd_bg_pc0 = 0, last_wr_bg_pc0 = 0;
  
  time last_rd_time_pc1 = 0, last_wr_time_pc1 = 0;
  logic [1:0] last_rd_bg_pc1 = 0, last_wr_bg_pc1 = 0;

  // Refresh and MRS Trackers
  time last_ref_time = 0;
  time last_refpb_time [NUM_BANKS];
  time last_refpb_any_time = 0; // Last REFpb to any bank (for tRREFD)
  time last_mrs_time = 0;

  // Per-Bank Refresh Rolling Window
  // Track the start of the current refresh window per bank
  time refpb_window_start [NUM_BANKS];
  int  refpb_window_count [NUM_BANKS]; // REFpb count within current window

  // ZQ Calibration Trackers
  time last_zq_time = 0;
  logic zq_cal_pending = 0;

  // Global command tracker for tCPDED (any command -> PDE delay)
  time last_any_cmd_time = 0;

  // Refresh Management (RFM) Trackers
  time last_rfm_time = 0;
  time last_rfmpb_time [NUM_BANKS];
  int  rfm_counter [NUM_BANKS]; // RAA (Row Activation Alarm) counter per bank

  // Directed Refresh Management (DRFM) Trackers
  time last_drfm_time [NUM_BANKS];

  // DBI Trackers
  logic [35:0] last_read_state_pc0 = '0; // {DBI[3:0], DQ[31:0]}
  logic [35:0] last_read_state_pc1 = '0;


  // Mode Registers
  logic [7:0] mode_reg_pc0 [20];
  logic [19:0] mr_programmed_pc0 = 0;
  logic [7:0] mode_reg_pc1 [20];
  logic [19:0] mr_programmed_pc1 = 0;

  // Loopback Mode (MR7 OP[0]) — last write data captured for readback
  logic [255:0] loopback_data_pc0 = '0;
  logic [255:0] loopback_data_pc1 = '0;

  // Power State
  typedef enum logic [1:0] {
    PWR_ACTIVE,
    PWR_PRE_PD,
    PWR_ACT_PD,
    PWR_SELF_REF
  } power_state_e;
  power_state_e power_state = PWR_ACTIVE;
  time last_pd_entry_time = 0;
  time last_pd_exit_time = 0;
  time last_sr_exit_time = 0;

  // Initialization State
  typedef enum logic [2:0] {
    INIT_IDLE,
    INIT_RESET_LOW,
    INIT_WAIT_PDE,
    INIT_WAIT_MRS,
    INIT_DONE
  } init_state_e;
  
  init_state_e init_state = INIT_IDLE;
  
  time reset_low_time = 0;
  time pde_entry_time = 0;
  time pde_exit_time = 0;
  
  logic aerr_out = 0;
  int aerr_timer = 0;
  assign vif.AERR = aerr_out;

  logic derr_out = 0;
  int derr_timer = 0;
  assign vif.DERR = derr_out;
  
  // Backdoor to inject an ECC error on the next read
  logic inject_ecc_error = 0;

  // Backdoor: inject a single-bit or multi-bit error into memory for ECC testing
  // Usage: model.inject_bit_error_pc0(addr, bit_pos) to flip a bit in stored data
  task automatic inject_bit_error_pc0(input int addr, input int bit_pos);
    if (mem_array_pc0.exists(addr)) begin
      mem_array_pc0[addr][bit_pos] = ~mem_array_pc0[addr][bit_pos];
      $display("[%0t] HBM4_ECC_TEST: Injected bit error at PC0 addr=0x%0h bit=%0d", $time, addr, bit_pos);
    end
  endtask

  task automatic inject_bit_error_pc1(input int addr, input int bit_pos);
    if (mem_array_pc1.exists(addr)) begin
      mem_array_pc1[addr][bit_pos] = ~mem_array_pc1[addr][bit_pos];
      $display("[%0t] HBM4_ECC_TEST: Injected bit error at PC1 addr=0x%0h bit=%0d", $time, addr, bit_pos);
    end
  endtask

  // Error Logging in Mode Registers
  // MR18: Error Status — [7:4] error type (1=parity, 2=ECC), [3:0] syndrome
  // MR19: Error Location — [7:6] bank group, [5:2] bank, [1:0] row addr bits
  task automatic log_parity_error();
    mode_reg_pc0[18] = {4'h1, 4'h0}; // Type=parity, syndrome=0
    mode_reg_pc1[18] = {4'h1, 4'h0};
    $display("[%0t] HBM4_MODEL: Parity error logged to MR18=0x%02h", $time, mode_reg_pc0[18]);
  endtask

  task automatic log_ecc_error(input logic [1:0] bg, input logic [3:0] ba, input logic [14:0] row, input logic [3:0] syndrome);
    mode_reg_pc0[18] = {4'h2, syndrome};     // Type=ECC, syndrome nibble
    mode_reg_pc1[18] = {4'h2, syndrome};
    mode_reg_pc0[19] = {bg, ba, row[1:0]};   // Bank group, bank, row LSBs
    mode_reg_pc1[19] = {bg, ba, row[1:0]};
    $display("[%0t] HBM4_MODEL: ECC error logged to MR18=0x%02h, MR19=0x%02h (BG=%0d, BA=%0d, Row=0x%04h)", 
             $time, mode_reg_pc0[18], mode_reg_pc0[19], bg, ba, row);
  endtask

  // Temperature Simulation
  localparam int CATTRIP_THRESHOLD = 125; // Catastrophic trip at 125°C
  int simulated_temp = 45; // Default simulated temperature (°C)
  logic cattrip_out = 0;
  assign vif.CATTRIP = cattrip_out;

  // CATTRIP monitoring
  always @(posedge vif.CK_t) begin
    if (!vif.RESET_n) begin
      cattrip_out <= 0;
    end else begin
      if (simulated_temp >= CATTRIP_THRESHOLD) begin
        if (!cattrip_out) begin
          cattrip_out <= 1;
          $display("[%0t] HBM4_MODEL: CATTRIP ASSERTED! Temperature %0d°C >= %0d°C threshold.", $time, simulated_temp, CATTRIP_THRESHOLD);
        end
      end else begin
        cattrip_out <= 0;
      end
    end
  end

  function automatic logic check_parity(aword_t a, dword_t d0, dword_t d1);
    logic calc_p_a;
    logic calc_p_d0;
    logic calc_p_d1;
    calc_p_a = ^({a.R_ADDR, a.BA, a.BG, a.CMD});
    calc_p_d0 = (d0.CMD == CMD_MRR || d0.CMD == CMD_MRS) ? d0.C : ^({d0.C_ADDR, d0.BA, d0.BG, d0.CMD});
    calc_p_d1 = (d1.CMD == CMD_MRR || d1.CMD == CMD_MRS) ? d1.C : ^({d1.C_ADDR, d1.BA, d1.BG, d1.CMD});
    return (calc_p_a == a.R) && (calc_p_d0 == d0.C) && (calc_p_d1 == d1.C);
  endfunction

  // Timing parameters from spec
  localparam time tPW_RESET = 1000ns; // 1 us
  localparam time tINIT5    = 200ns;
  
  // Reset sequence monitoring
  always @(negedge vif.RESET_n) begin
    init_state = INIT_RESET_LOW;
    reset_low_time = $time;
    $display("[%0t] HBM4_MODEL: RESET_n asserted (LOW).", $time);
  end
  
  always @(posedge vif.RESET_n) begin
    if (init_state == INIT_RESET_LOW) begin
      // Verify tPW_RESET
      // NOTE: Using a smaller value or checking strictly depends on BFM capability.
      // We check for >= 1us strictly as per spec, but allow a warning if close.
      if (($time - reset_low_time) < tPW_RESET && reset_low_time != 0) begin
        $error("[%0t] HBM4_PROTOCOL_ERROR: RESET_n held low for %0t, which is less than tPW_RESET (1us)!", $time, ($time - reset_low_time));
      end
      
      // Verify CK_t and CK_c are static LOW and HIGH
      if (vif.CK_t !== 1'b0 || vif.CK_c !== 1'b1) begin
        $error("[%0t] HBM4_PROTOCOL_ERROR: CK_t/CK_c must be driven static LOW/HIGH prior to RESET_n deassertion!", $time);
      end
      
      init_state = INIT_WAIT_PDE;
      $display("[%0t] HBM4_MODEL: RESET_n deasserted (HIGH). Waiting for PDE...", $time);
    end
  end

  // Local variables for burst handling
  logic read_valid_pc0;
  logic read_valid_pc1;
  logic [31:0] read_data_pc0;
  logic [31:0] read_data_pc1;
  logic [3:0]  read_dbi_pc0;
  logic [3:0]  read_dbi_pc1;

  // Drive DQ/DBI buses during read bursts (model → controller direction)
  assign vif.DQ_PC0  = read_valid_pc0 ? read_data_pc0 : 32'hz;
  assign vif.DBI_PC0 = read_valid_pc0 ? read_dbi_pc0  : 4'hz;
  assign vif.DQ_PC1  = read_valid_pc1 ? read_data_pc1 : 32'hz;
  assign vif.DBI_PC1 = read_valid_pc1 ? read_dbi_pc1  : 4'hz;

  initial begin
    read_valid_pc0 = 0;
    read_valid_pc1 = 0;
    read_data_pc0 = 32'hz;
    read_data_pc1 = 32'hz;
    read_dbi_pc0  = 4'hz;
    read_dbi_pc1  = 4'hz;
    vif.RDQS_t_PC0 = 0;
    vif.RDQS_c_PC0 = 1;
    vif.RDQS_t_PC1 = 0;
    vif.RDQS_c_PC1 = 1;
  end

  initial begin
    for (int i = 0; i < 20; i++) begin
      mode_reg_pc0[i] = 0;
      mode_reg_pc1[i] = 0;
    end
    last_ref_time = 0;
    last_mrs_time = 0;
    for (int i = 0; i < NUM_BANKS; i++) begin
      bank_state[i] = BANK_IDLE;
      last_act_time[i] = 0;
      last_pre_time[i] = 0;
      last_bank_wr_time[i] = 0;
      last_bank_rd_time[i] = 0;
      refpb_window_start[i] = 0;
      refpb_window_count[i] = 0;
    end
  end

  // Command decoding logic (Simplified)
  // AWORD commands (sampled on rising edge of CK)
  always @(posedge vif.CK_t) begin
    if (!vif.RESET_n) begin
      // State reset handled asynchronously
      last_rd_time_pc0 <= 0; last_wr_time_pc0 <= 0;
      last_rd_time_pc1 <= 0; last_wr_time_pc1 <= 0;
      last_ref_time <= 0;
      last_mrs_time <= 0;
      for (int i = 0; i < 20; i++) begin
        mode_reg_pc0[i] <= 0;
        mode_reg_pc1[i] <= 0;
      end
      mr_programmed_pc0 <= 0;
      mr_programmed_pc1 <= 0;
      for (int i = 0; i < NUM_BANKS; i++) begin
        bank_state[i] <= BANK_IDLE;
        last_act_time[i] <= 0;
        last_pre_time[i] <= 0;
        last_bank_wr_time[i] <= 0;
        last_bank_rd_time[i] <= 0;
        last_refpb_time[i] <= 0;
        refpb_window_start[i] <= 0;
        refpb_window_count[i] <= 0;
      end
      for (int i=0; i<4; i++) act_history[i] <= 0;
      last_global_act_time <= 0;
      aerr_timer <= 0;
      aerr_out <= 0;
      power_state <= PWR_ACTIVE;
      last_pd_entry_time <= 0;
      last_pd_exit_time <= 0;
      last_sr_exit_time <= 0;
      last_zq_time <= 0;
      zq_cal_pending <= 0;
    end else begin
      // Decode AWORD command
      aword_t aword;
      dword_t dword_pc0;
      dword_t dword_pc1;
      
      if (aerr_timer > 0) begin
        aerr_timer <= aerr_timer - 1;
        if (aerr_timer == 1) aerr_out <= 0;
      end
      if (derr_timer > 0) begin
        derr_timer <= derr_timer - 1;
        if (derr_timer == 1) derr_out <= 0;
      end

      aword = vif.AWORD;
      dword_pc0 = dword_t'(vif.DWORD_PC0);
      dword_pc1 = dword_t'(vif.DWORD_PC1);
      
      if (!check_parity(aword, dword_pc0, dword_pc1)) begin
         $display("[%0t] HBM4_MODEL: PARITY ERROR DETECTED. Ignoring commands.", $time);
         aerr_out <= 1;
         aerr_timer <= 4;
         log_parity_error();
      end else begin
      // Initialization Sequence Checking
      if (init_state != INIT_DONE) begin
        if (init_state == INIT_WAIT_PDE) begin
          if (aword.CMD == CMD_PDE && dword_pc0.CMD == CMD_CNOP && dword_pc1.CMD == CMD_CNOP) begin
            init_state = INIT_WAIT_MRS;
            pde_entry_time = $time;
            $display("[%0t] HBM4_MODEL: Entered PDE state during initialization.", $time);
          end else begin
            $error("[%0t] HBM4_PROTOCOL_ERROR: Command must be PDE and DWORD NOP upon first CK toggle after reset! Got AWORD=%0h", $time, aword.CMD);
          end
        end else if (init_state == INIT_WAIT_MRS) begin
          if (aword.CMD == CMD_RNOP && dword_pc0.CMD == CMD_CNOP && dword_pc1.CMD == CMD_CNOP) begin
            if (pde_exit_time == 0) begin
              pde_exit_time = $time;
              $display("[%0t] HBM4_MODEL: Exited PDE state. Waiting tINIT5 (200ns) before first MRS...", $time);
            end
          end else if (aword.CMD == CMD_PDE) begin
            // Stay in PDE
          end else if (dword_pc0.CMD == CMD_MRS || dword_pc1.CMD == CMD_MRS) begin
            if (pde_exit_time == 0) begin
              $error("[%0t] HBM4_PROTOCOL_ERROR: MRS command issued without exiting PDE first!", $time);
            end else if (($time - pde_exit_time) < tINIT5) begin
              $error("[%0t] HBM4_PROTOCOL_ERROR: First MRS command issued before tINIT5 (200ns) elapsed!", $time);
            end else begin
              // Wait for all MRs to be programmed
            end
          end else begin
            $error("[%0t] HBM4_PROTOCOL_ERROR: Illegal command %0h during initialization! Only PDE, NOP, or MRS allowed.", $time, aword.CMD);
          end
        end
      end
      
      
      // Process MRS Commands
      if (dword_pc0.CMD == CMD_MRS) begin
        automatic int mr_idx = {dword_pc0.C, dword_pc0.BA};
        // tXSMRS: MRS not allowed too soon after Self-Refresh Exit
        if (last_sr_exit_time != 0 && ($time - last_sr_exit_time) < tXSMRS) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tXSMRS violation on MRS PC0. SR exit was %0t ago, minimum is %0t.", $time, ($time - last_sr_exit_time), tXSMRS);
        end
        mode_reg_pc0[mr_idx] <= {dword_pc0.BG, dword_pc0.C_ADDR};
        mr_programmed_pc0[mr_idx] <= 1;
        $display("[%0t] HBM4_MODEL: Programmed PC0 MR%0d", $time, mr_idx);
        last_mrs_time <= $time;
        last_any_cmd_time <= $time;
      end
      if (dword_pc1.CMD == CMD_MRS) begin
        automatic int mr_idx = {dword_pc1.C, dword_pc1.BA};
        if (last_sr_exit_time != 0 && ($time - last_sr_exit_time) < tXSMRS) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tXSMRS violation on MRS PC1. SR exit was %0t ago, minimum is %0t.", $time, ($time - last_sr_exit_time), tXSMRS);
        end
        mode_reg_pc1[mr_idx] <= {dword_pc1.BG, dword_pc1.C_ADDR};
        mr_programmed_pc1[mr_idx] <= 1;
        last_mrs_time <= $time;
        last_any_cmd_time <= $time;
      end

      if (init_state == INIT_WAIT_MRS && mr_programmed_pc0 == 20'hFFFFF && mr_programmed_pc1 == 20'hFFFFF) begin
         init_state = INIT_DONE;
         $display("[%0t] HBM4_MODEL: Initialization sequence completed successfully.", $time);
      end

      if (init_state == INIT_DONE || (init_state == INIT_WAIT_MRS && (dword_pc0.CMD == CMD_MRS || dword_pc1.CMD == CMD_MRS))) begin
        if (aword.CMD == CMD_ACT) begin

        int bank_idx;
        if (mr_programmed_pc0 != 20'hFFFFF || mr_programmed_pc1 != 20'hFFFFF) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: ACTIVATE issued before all 20 Mode Registers were programmed!", $time);
        end

                
        bank_idx = {aword.BG, aword.BA};
        
        // Protocol Check
        if (power_state != PWR_ACTIVE) $error("[%0t] HBM4_PROTOCOL_ERROR: Command issued while in low-power state!", $time);
        if (($time - last_sr_exit_time) < tXS && last_sr_exit_time != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tXS violation.", $time);
        end
        if (($time - last_pd_exit_time) < tXP && last_pd_exit_time != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tXP violation. Expected %0t, got %0t.", $time, tXP, ($time - last_pd_exit_time));
        end
        
        // DRFM: Directed Refresh Management (ACT with DRFM bit set)
        if (aword.R_ADDR[DRFM_BIT]) begin
          if (bank_state[bank_idx] != BANK_IDLE) begin
            $error("[%0t] HBM4_PROTOCOL_ERROR: DRFM to active bank %0d!", $time, bank_idx);
          end
          if (($time - last_drfm_time[bank_idx]) < tDRFM && last_drfm_time[bank_idx] != 0) begin
          timing_violation_count++;
            $error("[%0t] HBM4_TIMING_ERROR: tDRFM violation on bank %0d.", $time, bank_idx);
          end
          
          last_drfm_time[bank_idx] <= $time;
          rfm_counter[bank_idx] <= 0; // Reset RAA counter
          last_act_time[bank_idx] <= $time;
          last_any_cmd_time <= $time;
          $display("[%0t] HBM4_MODEL: DRFM Bank %0d, Row %0h (RAA counter reset)", $time, bank_idx, aword.R_ADDR);
        end else begin
        // Normal ACTIVATE
        if (bank_state[bank_idx] != BANK_IDLE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: ACTIVATE to already active bank %0d!", $time, bank_idx);
        end
        
        // Refresh Starvation Check
        if (($time - last_ref_time) > tREFI && last_ref_time != 0) begin
           $error("[%0t] HBM4_PROTOCOL_ERROR: Refresh Starvation! tREFI violation.", $time);
        end
        // Per-Bank Refresh Window Check
        if (last_refpb_time[bank_idx] != 0 && ($time - last_refpb_time[bank_idx]) > tREFW) begin
           $warning("[%0t] HBM4_PROTOCOL_WARNING: Per-bank refresh window (tREFW=%0t) exceeded for bank %0d. Last REFpb was %0t ago.", $time, tREFW, bank_idx, ($time - last_refpb_time[bank_idx]));
        end
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on ACTIVATE. Command issued during refresh.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on ACTIVATE. Command issued too soon after MRS.", $time);
        end
        
        // Timing Check: tRP
        if (($time - last_pre_time[bank_idx]) < tRP && last_pre_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRP violation on bank %0d. Expected %0t, got %0t", $time, bank_idx, tRP, ($time - last_pre_time[bank_idx]));
        end
        
        // Timing Check: tRC
        if (($time - last_act_time[bank_idx]) < tRC && last_act_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRC violation on bank %0d. Expected %0t, got %0t", $time, bank_idx, tRC, ($time - last_act_time[bank_idx]));
        end

        // Timing Check: tFAW
        if (($time - act_history[3]) < tFAW && act_history[3] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tFAW violation. 5th ACTIVATE issued within %0t (< %0t)", $time, ($time - act_history[3]), tFAW);
        end

        // Timing Check: tRRD_L and tRRD_S
        if (last_global_act_time != 0) begin
          time trrd_val;
          trrd_val = (aword.BG == last_act_bg) ? tRRD_L : tRRD_S;
          if (($time - last_global_act_time) < trrd_val) begin
          timing_violation_count++;
             $error("[%0t] HBM4_TIMING_ERROR: tRRD violation. Expected %0t, got %0t", $time, trrd_val, ($time - last_global_act_time));
          end
        end

        // Execute Command
        bank_state[bank_idx] <= BANK_ACTIVE;
        active_row[bank_idx] <= remap_row(aword.BG, aword.BA, aword.R_ADDR);
        last_act_time[bank_idx] <= $time;
        last_any_cmd_time <= $time;
        rfm_counter[bank_idx] <= rfm_counter[bank_idx] + 1; // RAA counter increment
        
        // RFM threshold warning: MR8 OP[5:4] sets RAA multiplier (0=32, 1=48, 2=64, 3=80)
        begin
          int raa_threshold;
          raa_threshold = 32 + (mode_reg_pc0[8][5:4] * 16);
          if ((rfm_counter[bank_idx] + 1) >= raa_threshold) begin
            $warning("[%0t] HBM4_RFM_WARNING: Bank %0d RAA counter (%0d) reached threshold (%0d). RFM recommended.", $time, bank_idx, rfm_counter[bank_idx] + 1, raa_threshold);
          end
        end
        
        act_history[3] <= act_history[2];
        act_history[2] <= act_history[1];
        act_history[1] <= act_history[0];
        act_history[0] <= $time;
        last_global_act_time <= $time;
        last_act_bg <= aword.BG;
        
        $display("[%0t] HBM4_MODEL: ACTIVATE Bank %0d, Row %0h", $time, bank_idx, aword.R_ADDR);
        end // end normal ACTIVATE (else of DRFM check)
      end
      else if (aword.CMD == CMD_PRE) begin
                int bank_idx;
        bank_idx = {aword.BG, aword.BA};
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: PRECHARGE to idle bank %0d!", $time, bank_idx);
        end
        
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on PRECHARGE.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on PRECHARGE.", $time);
        end
        
        // Timing Check: tRAS
        if (($time - last_act_time[bank_idx]) < tRAS && last_act_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRAS violation on bank %0d. Expected %0t, got %0t", $time, bank_idx, tRAS, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tWR
        if (($time - last_bank_wr_time[bank_idx]) < tWR && last_bank_wr_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tWR violation on PRECHARGE bank %0d. Expected %0t, got %0t", $time, bank_idx, tWR, ($time - last_bank_wr_time[bank_idx]));
        end
        
        // Timing Check: tRTP (same bank group → tRTP_L)
        if (($time - last_bank_rd_time[bank_idx]) < tRTP_L && last_bank_rd_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRTP violation on PRECHARGE bank %0d. Expected %0t, got %0t", $time, bank_idx, tRTP_L, ($time - last_bank_rd_time[bank_idx]));
        end
        
        // Execute Command
        bank_state[bank_idx] <= BANK_IDLE;
        last_pre_time[bank_idx] <= $time;
        last_any_cmd_time <= $time;
        $display("[%0t] HBM4_MODEL: PRECHARGE Bank %0d", $time, bank_idx);
      end
      else if (aword.CMD == CMD_PREA) begin
        // Check tRFC
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on PREA.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on PREA.", $time);
        end
        
        for (int i = 0; i < NUM_BANKS; i++) begin
          if (bank_state[i] == BANK_ACTIVE) begin
            // Timing Check: tRAS
            if (($time - last_act_time[i]) < tRAS && last_act_time[i] != 0) begin
          timing_violation_count++;
              $error("[%0t] HBM4_TIMING_ERROR: tRAS violation on PREA bank %0d. Expected %0t, got %0t", $time, i, tRAS, ($time - last_act_time[i]));
            end
            // Timing Check: tWR
            if (($time - last_bank_wr_time[i]) < tWR && last_bank_wr_time[i] != 0) begin
          timing_violation_count++;
              $error("[%0t] HBM4_TIMING_ERROR: tWR violation on PREA bank %0d. Expected %0t, got %0t", $time, i, tWR, ($time - last_bank_wr_time[i]));
            end
            // Timing Check: tRTP (same bank → tRTP_L)
            if (($time - last_bank_rd_time[i]) < tRTP_L && last_bank_rd_time[i] != 0) begin
          timing_violation_count++;
              $error("[%0t] HBM4_TIMING_ERROR: tRTP violation on PREA bank %0d. Expected %0t, got %0t", $time, i, tRTP_L, ($time - last_bank_rd_time[i]));
            end
            
            bank_state[i] <= BANK_IDLE;
            last_pre_time[i] <= $time;
          end
        end
        $display("[%0t] HBM4_MODEL: PRECHARGE ALL", $time);
      end
      else if (aword.CMD == CMD_REFpb) begin
        int bank_idx;
        bank_idx = {aword.BG, aword.BA};

        if (bank_state[bank_idx] != BANK_IDLE) begin
           $error("[%0t] HBM4_PROTOCOL_ERROR: REFpb command issued to ACTIVE bank %0d!", $time, bank_idx);
        end
        // Check tRFCpb
        if (($time - last_refpb_time[bank_idx]) < tRFCpb && last_refpb_time[bank_idx] != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFCpb violation on REFpb bank %0d.", $time, bank_idx);
        end
        // Also respect all-bank refresh
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on REFpb.", $time);
        end
        // tRREFD: minimum delay between consecutive REFpb commands
        if (($time - last_refpb_any_time) < tRREFD && last_refpb_any_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRREFD violation on REFpb bank %0d. Expected %0t, got %0t", $time, bank_idx, tRREFD, ($time - last_refpb_any_time));
        end

        last_refpb_time[bank_idx] <= $time;
        last_refpb_any_time <= $time;
        last_any_cmd_time <= $time;
        
        // Rolling window tracking
        if (refpb_window_start[bank_idx] == 0 || ($time - refpb_window_start[bank_idx]) >= tREFW) begin
          // Start new window
          refpb_window_start[bank_idx] <= $time;
          refpb_window_count[bank_idx] <= 1;
        end else begin
          refpb_window_count[bank_idx] <= refpb_window_count[bank_idx] + 1;
        end
        
        $display("[%0t] HBM4_MODEL: PER-BANK REFRESH Bank %0d (window count: %0d)", $time, bank_idx, refpb_window_count[bank_idx] + 1);
      end
      else if (aword.CMD == CMD_REF) begin
        // Check if all banks are idle
        for (int i = 0; i < NUM_BANKS; i++) begin
           if (bank_state[i] != BANK_IDLE) begin
               $error("[%0t] HBM4_PROTOCOL_ERROR: REF command issued while bank %0d is ACTIVE!", $time, i);
           end
        end
        // Check tRFC
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on REF.", $time);
        end
        last_ref_time <= $time;
        last_any_cmd_time <= $time;
        $display("[%0t] HBM4_MODEL: ALL-BANK REFRESH", $time);
      end
      else if (aword.CMD == CMD_PDE) begin
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: PDE issued while not in ACTIVE state (current: %s)!", $time, power_state.name());
        end
        // tCPDED: minimum delay from last command to PDE
        if (last_any_cmd_time != 0 && ($time - last_any_cmd_time) < tCPDED) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tCPDED violation on PDE. Last command was %0t ago, minimum is %0t.", $time, ($time - last_any_cmd_time), tCPDED);
        end
        // tWRPDE: write recovery must complete before PDE
        if (last_wr_time_pc0 != 0 && ($time - last_wr_time_pc0) < tWRPDE) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tWRPDE violation on PDE (PC0 write too recent).", $time);
        end
        if (last_wr_time_pc1 != 0 && ($time - last_wr_time_pc1) < tWRPDE) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tWRPDE violation on PDE (PC1 write too recent).", $time);
        end
        // Determine pre-PD or active-PD based on bank states
        begin
          logic any_active = 0;
          for (int i = 0; i < NUM_BANKS; i++) begin
            if (bank_state[i] == BANK_ACTIVE) any_active = 1;
          end
          if (any_active)
            power_state <= PWR_ACT_PD;
          else
            power_state <= PWR_PRE_PD;
        end
        last_pd_entry_time <= $time;
        $display("[%0t] HBM4_MODEL: POWER-DOWN ENTRY", $time);
      end
      else if (aword.CMD == CMD_PDX) begin
        if (power_state != PWR_PRE_PD && power_state != PWR_ACT_PD) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: PDX issued while not in Power-Down state (current: %s)!", $time, power_state.name());
        end
        // Check tPD minimum
        if (($time - last_pd_entry_time) < tPD && last_pd_entry_time != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tPD violation on PDX. Power-Down held for %0t, minimum is %0t.", $time, ($time - last_pd_entry_time), tPD);
        end
        power_state <= PWR_ACTIVE;
        last_pd_exit_time <= $time;
        $display("[%0t] HBM4_MODEL: POWER-DOWN EXIT", $time);
      end
      else if (aword.CMD == CMD_SRE) begin
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: SRE issued while not in ACTIVE state (current: %s)!", $time, power_state.name());
        end
        // All banks must be idle for self-refresh
        for (int i = 0; i < NUM_BANKS; i++) begin
          if (bank_state[i] != BANK_IDLE) begin
            $error("[%0t] HBM4_PROTOCOL_ERROR: SRE issued while bank %0d is ACTIVE!", $time, i);
          end
        end
        power_state <= PWR_SELF_REF;
        $display("[%0t] HBM4_MODEL: SELF-REFRESH ENTRY", $time);
      end
      else if (aword.CMD == CMD_SRX) begin
        if (power_state != PWR_SELF_REF) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: SRX issued while not in Self-Refresh state (current: %s)!", $time, power_state.name());
        end
        power_state <= PWR_ACTIVE;
        last_sr_exit_time <= $time;
        $display("[%0t] HBM4_MODEL: SELF-REFRESH EXIT", $time);
      end
      else if (aword.CMD == CMD_ZQ) begin
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: ZQ calibration issued while not in ACTIVE state!", $time);
        end
        // ZQ cal type determined by BA[0]: 0=Short (ZQCS), 1=Long (ZQCL)
        if (aword.BA[0]) begin
          // ZQCL - long calibration
          if (($time - last_zq_time) < tZQCL && last_zq_time != 0) begin
          timing_violation_count++;
            $error("[%0t] HBM4_TIMING_ERROR: tZQCL violation. Previous ZQ cal too recent.", $time);
          end
          $display("[%0t] HBM4_MODEL: ZQ CALIBRATION LONG (ZQCL)", $time);
        end else begin
          // ZQCS - short calibration
          if (($time - last_zq_time) < tZQCS && last_zq_time != 0) begin
          timing_violation_count++;
            $error("[%0t] HBM4_TIMING_ERROR: tZQCS violation. Previous ZQ cal too recent.", $time);
          end
          $display("[%0t] HBM4_MODEL: ZQ CALIBRATION SHORT (ZQCS)", $time);
        end
        last_zq_time <= $time;
        last_any_cmd_time <= $time;
        zq_cal_pending <= 1;
      end
      else if (aword.CMD == CMD_RFM) begin
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: RFM issued while not in ACTIVE state!", $time);
        end
        
        if (aword.BA[3]) begin
          // RFMpb — per-bank refresh management
          int bank_idx;
          bank_idx = {aword.BG, aword.BA[2:0], 1'b0}; // Lower bits select bank
          
          if (bank_state[bank_idx] != BANK_IDLE) begin
            $error("[%0t] HBM4_PROTOCOL_ERROR: RFMpb issued to ACTIVE bank %0d!", $time, bank_idx);
          end
          if (($time - last_rfmpb_time[bank_idx]) < tRFMpb && last_rfmpb_time[bank_idx] != 0) begin
          timing_violation_count++;
            $error("[%0t] HBM4_TIMING_ERROR: tRFMpb violation on bank %0d.", $time, bank_idx);
          end
          
          last_rfmpb_time[bank_idx] <= $time;
          last_any_cmd_time <= $time;
          rfm_counter[bank_idx] <= 0; // Reset RAA counter
          $display("[%0t] HBM4_MODEL: RFMpb Bank %0d (RAA counter reset)", $time, bank_idx);
        end else begin
          // RFMab — all-bank refresh management
          for (int i = 0; i < NUM_BANKS; i++) begin
            if (bank_state[i] != BANK_IDLE) begin
              $error("[%0t] HBM4_PROTOCOL_ERROR: RFMab issued while bank %0d is ACTIVE!", $time, i);
            end
          end
          if (($time - last_rfm_time) < tRFM && last_rfm_time != 0) begin
          timing_violation_count++;
            $error("[%0t] HBM4_TIMING_ERROR: tRFM violation on RFMab.", $time);
          end
          
          last_rfm_time <= $time;
          last_any_cmd_time <= $time;
          for (int i = 0; i < NUM_BANKS; i++) rfm_counter[i] <= 0;
          $display("[%0t] HBM4_MODEL: RFMab (all RAA counters reset)", $time);
        end
      end
      end // End of initialized condition
      end // End of parity else block
    end
  end

  initial begin
    read_valid_pc0 = 0;
    read_valid_pc1 = 0;
    read_data_pc0 = 32'hz;
    read_data_pc1 = 32'hz;
    read_dbi_pc0  = 4'hz;
    read_dbi_pc1  = 4'hz;
    vif.RDQS_t_PC0 = 0;
    vif.RDQS_c_PC0 = 1;
    vif.RDQS_t_PC1 = 0;
    vif.RDQS_c_PC1 = 1;
  end

  initial begin
    for (int i = 0; i < 20; i++) begin
      mode_reg_pc0[i] = 0;
      mode_reg_pc1[i] = 0;
    end
    last_ref_time = 0;
    last_mrs_time = 0;
    for (int i = 0; i < NUM_BANKS; i++) begin
      bank_state[i] = BANK_IDLE;
      last_act_time[i] = 0;
      last_pre_time[i] = 0;
      last_bank_wr_time[i] = 0;
      last_bank_rd_time[i] = 0;
      last_rfmpb_time[i] = 0;
      rfm_counter[i] = 0;
      last_drfm_time[i] = 0;
    end
  end


    // DWORD commands
  always @(posedge vif.CK_t) begin
    if (vif.RESET_n) begin
      dword_t dword_pc0;
      dword_t dword_pc1;
      dword_pc0 = vif.DWORD_PC0;
      dword_pc1 = vif.DWORD_PC1;
      
      // Handle PC0
      if (dword_pc0.CMD == CMD_WR) begin

        int bank_idx;
        if (mr_programmed_pc0 != 20'hFFFFF || mr_programmed_pc1 != 20'hFFFFF) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ issued before all 20 Mode Registers were programmed!", $time);
        end

                
        bank_idx = {dword_pc0.BG, dword_pc0.BA};
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: WRITE PC0 to idle bank %0d!", $time, bank_idx);
        end
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: WRITE PC0 issued while in low-power state (%s)!", $time, power_state.name());
        end
        
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on WRITE PC0.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on WRITE PC0.", $time);
        end
        
        // Timing Check: tRCDWR
        if (($time - last_act_time[bank_idx]) < tRCDWR && last_act_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRCDWR violation on WRITE PC0 bank %0d. Expected %0t, got %0t", $time, bank_idx, tRCDWR, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tCCD (WR to WR)
        if (last_wr_time_pc0 != 0) begin
          time tccd_val;
          tccd_val = (dword_pc0.BG == last_wr_bg_pc0) ? tCCD_L : tCCD_S;
          if (($time - last_wr_time_pc0) < tccd_val) begin
          timing_violation_count++;
             $error("[%0t] HBM4_TIMING_ERROR: tCCD violation on WRITE PC0. Expected %0t, got %0t", $time, tccd_val, ($time - last_wr_time_pc0));
          end
        end
        
        // Timing Check: tRTW (RD to WR)
        if (($time - last_rd_time_pc0) < tRTW && last_rd_time_pc0 != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRTW violation on WRITE PC0. Expected %0t, got %0t", $time, tRTW, ($time - last_rd_time_pc0));
        end
        
        last_wr_time_pc0 <= $time;
        last_any_cmd_time <= $time;
        last_wr_bg_pc0 <= dword_pc0.BG;
        last_bank_wr_time[bank_idx] <= $time;
        
        // Execute Command
        begin
          automatic int b_idx = bank_idx;
          automatic int c_addr = dword_pc0.C_ADDR;
          automatic int addr = {dword_pc0.BG, dword_pc0.BA, active_row[bank_idx], dword_pc0.C_ADDR};
          automatic int dynamic_wl = (mode_reg_pc0[1] != 0) ? mode_reg_pc0[1][4:0] : 8;
          
          $display("[%0t] HBM4_MODEL: WRITE PC0 Bank %0d, Col %0h (WL=%0d)", $time, b_idx, c_addr, dynamic_wl);
          
          fork
            begin
              automatic logic [255:0] write_data;
              automatic logic [31:0]  write_mask; // Per-byte mask for DM mode
              // WDBI is controlled by MR0 OP[1]
              automatic logic wdbi_en = (mode_reg_pc0[0][1] == 1'b1);
              // Data Mask mode controlled by MR0 OP[3] (overrides DBI on writes)
              automatic logic dm_en = (mode_reg_pc0[0][3] == 1'b1);
              repeat(dynamic_wl) @(posedge vif.CK_t);
              
              // Skip write preamble (model starts 1 CK into the 2 CK preamble)
              repeat(2) begin
                @(posedge vif.WDQS_t_PC0);
                @(negedge vif.WDQS_t_PC0);
              end
              
              write_data = mem_array_pc0.exists(addr) ? mem_array_pc0[addr] : 256'h0;
              write_mask = '0;
              
              for (int beat = 0; beat < 4; beat++) begin
                automatic logic [31:0] dq_sampled;
                automatic logic [3:0]  dbi_sampled;
                
                @(posedge vif.WDQS_t_PC0);
                dq_sampled = vif.DQ_PC0;
                dbi_sampled = vif.DBI_PC0;
                for (int b = 0; b < 4; b++) begin
                  if (dm_en && dbi_sampled[b]) begin
                    // DM mode: mask this byte (keep existing data)
                  end else begin
                    write_data[(beat*2)*32 + b*8 +: 8] = (wdbi_en && !dm_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                  end
                end
                
                @(negedge vif.WDQS_t_PC0);
                dq_sampled = vif.DQ_PC0;
                dbi_sampled = vif.DBI_PC0;
                for (int b = 0; b < 4; b++) begin
                  if (dm_en && dbi_sampled[b]) begin
                    // DM mode: mask this byte (keep existing data)
                  end else begin
                    write_data[(beat*2+1)*32 + b*8 +: 8] = (wdbi_en && !dm_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                  end
                end
              end
              mem_array_pc0[addr] = write_data;
              ecc_array_pc0[addr] = ecc_encode(write_data); // Store ECC check bits
              // Loopback mode: capture write data for immediate readback
              if (mode_reg_pc0[7][0]) loopback_data_pc0 = write_data;
              
              // Auto-Precharge: close bank after write recovery (tWR)
              if (c_addr[AP_BIT]) begin
                #(tWR);
                bank_state[b_idx] <= BANK_IDLE;
                last_pre_time[b_idx] <= $time;
                $display("[%0t] HBM4_MODEL: AUTO-PRECHARGE (WRA) Bank %0d", $time, b_idx);
              end
              
              // Reset Read DBI state on write-to-read turnaround (as per spec)
              last_read_state_pc0 = '0;
            end
          join_none
        end
      end
      else if (dword_pc0.CMD == CMD_RD) begin
                int bank_idx;
        bank_idx = {dword_pc0.BG, dword_pc0.BA};
        
        if (inject_ecc_error) begin
            $display("[%0t] HBM4_MODEL: INTERNAL ECC ERROR DETECTED on PC0. Asserting DERR.", $time);
            derr_out <= 1;
            derr_timer <= 4;
            inject_ecc_error <= 0;
            log_ecc_error(dword_pc0.BG, dword_pc0.BA, active_row[bank_idx], 4'hA);
            // MR9 OP[0]: ECC metadata signaling enable
            if (mode_reg_pc0[9][0]) begin
              $display("[%0t] HBM4_MODEL: ECC metadata enabled - syndrome=0xA, bank=%0d", $time, bank_idx);
            end
        end
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ PC0 to idle bank %0d!", $time, bank_idx);
        end
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ PC0 issued while in low-power state (%s)!", $time, power_state.name());
        end
        
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on READ PC0.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on READ PC0.", $time);
        end
        
        // Timing Check: tRCDRD
        if (($time - last_act_time[bank_idx]) < tRCDRD && last_act_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRCDRD violation on READ PC0 bank %0d. Expected %0t, got %0t", $time, bank_idx, tRCDRD, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tCCD (RD to RD)
        if (last_rd_time_pc0 != 0) begin
          time tccd_val;
          tccd_val = (dword_pc0.BG == last_rd_bg_pc0) ? tCCD_L : tCCD_S;
          if (($time - last_rd_time_pc0) < tccd_val) begin
          timing_violation_count++;
             $error("[%0t] HBM4_TIMING_ERROR: tCCD violation on READ PC0. Expected %0t, got %0t", $time, tccd_val, ($time - last_rd_time_pc0));
          end
        end
        
        // Timing Check: tWTR (WR to RD)
        if (last_wr_time_pc0 != 0) begin
          time twtr_val;
          twtr_val = (dword_pc0.BG == last_wr_bg_pc0) ? tWTR_L : tWTR_S;
          if (($time - last_wr_time_pc0) < twtr_val) begin
          timing_violation_count++;
             $error("[%0t] HBM4_TIMING_ERROR: tWTR violation on READ PC0. Expected %0t, got %0t", $time, twtr_val, ($time - last_wr_time_pc0));
          end
        end
        
        last_rd_time_pc0 <= $time;
        last_any_cmd_time <= $time;
        last_rd_bg_pc0 <= dword_pc0.BG;
        last_bank_rd_time[bank_idx] <= $time;
        
        // Execute Command
        begin
          fork
            begin
              logic [31:0] ui0_data;
              logic [31:0] ui1_data;
              logic [35:0] next_st;
              logic rdbi_en;
              int addr;
              logic [255:0] read_data_256;
              automatic int dynamic_rl = (mode_reg_pc0[2] != 0) ? mode_reg_pc0[2] : 14;
              automatic int b_idx = {dword_pc0.BG, dword_pc0.BA};
              addr = {dword_pc0.BG, dword_pc0.BA, active_row[b_idx], dword_pc0.C_ADDR};
              
              // Wait for RL (preamble starts 2 tCK early)
              repeat(dynamic_rl - 2) @(posedge vif.CK_t);
              
              // Drive Preamble (2 tCK = 4 WCK half-cycles, ends low for clean data posedge)
              vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1; @(posedge vif.WCK_t);
              
              rdbi_en = (mode_reg_pc0[0][2] == 1'b1);
              // Loopback mode: return last written data instead of memory contents
              if (mode_reg_pc0[7][0])
                read_data_256 = loopback_data_pc0;
              else begin
                read_data_256 = mem_array_pc0.exists(addr) ? mem_array_pc0[addr] : 256'h0;
                // On-die ECC decode: check and correct on read
                if (ecc_array_pc0.exists(addr)) begin
                  ecc_result_t ecc_res;
                  ecc_res = ecc_decode(read_data_256, ecc_array_pc0[addr]);
                  if (ecc_res.sec_error) begin
                    read_data_256 = ecc_res.data;
                    mem_array_pc0[addr] = ecc_res.data; // Scrub corrected data
                    ecc_sec_count++;
                    $display("[%0t] HBM4_ECC: SEC corrected on PC0 read addr=0x%0h", $time, addr);
                  end
                  if (ecc_res.ded_error) begin
                    ecc_ded_count++;
                    derr_out <= 1;
                    derr_timer <= 4;
                    log_ecc_error(dword_pc0.BG, dword_pc0.BA, active_row[b_idx], 4'hB);
                    $display("[%0t] HBM4_ECC: DED uncorrectable on PC0 read addr=0x%0h. DERR asserted.", $time, addr);
                  end
                end
              end
              
              for (int beat = 0; beat < 4; beat++) begin
                ui0_data = read_data_256[(beat*2)*32 +: 32];
                ui1_data = read_data_256[(beat*2+1)*32 +: 32];
                
                begin : rdbi_processing_pc0
                  next_st = hbm4_pkg::process_dbi_word(ui0_data, last_read_state_pc0, rdbi_en);
                  read_data_pc0 = next_st[31:0];
                  read_dbi_pc0 = next_st[35:32];
                  read_valid_pc0 = 1;
                  last_read_state_pc0 = next_st;
                  
                  vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0;
                  
                  @(negedge vif.WCK_t);
                  
                  next_st = hbm4_pkg::process_dbi_word(ui1_data, last_read_state_pc0, rdbi_en);
                  read_data_pc0 = next_st[31:0];
                  read_dbi_pc0 = next_st[35:32];
                  last_read_state_pc0 = next_st;
                  
                  vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1;
                  @(posedge vif.WCK_t);
                end
              end
              
              // Postamble (2 WCK pulses)
              vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1; @(posedge vif.WCK_t);
              read_valid_pc0 = 0;
              
              // Auto-Precharge: close bank after tRTP
              if (dword_pc0.C_ADDR[AP_BIT]) begin
                #(tRTP_L);
                bank_state[b_idx] <= BANK_IDLE;
                last_pre_time[b_idx] <= $time;
                $display("[%0t] HBM4_MODEL: AUTO-PRECHARGE (RDA) Bank %0d", $time, b_idx);
              end
            end
          join_none
        end
      end
      else if (dword_pc0.CMD == CMD_MRR) begin
        // Mode Register Read for PC0
        begin
          automatic int mr_idx = {dword_pc0.C, dword_pc0.BA};
          automatic logic [7:0] mr_val = (mr_idx == 4) ? simulated_temp[7:0] : mode_reg_pc0[mr_idx];
          automatic int dynamic_rl = (mode_reg_pc0[2] != 0) ? mode_reg_pc0[2] : 14;
          
          $display("[%0t] HBM4_MODEL: MRR PC0 MR%0d = 0x%02h (RL=%0d)", $time, mr_idx, mr_val, dynamic_rl);
          last_rd_time_pc0 <= $time;
          last_any_cmd_time <= $time;
          
          fork
            begin
              logic [31:0] mrr_data;
              logic [35:0] next_st;
              logic rdbi_en;
              
              // MRR returns MR value replicated across all bytes
              mrr_data = {4{mr_val}};
              
              repeat(dynamic_rl - 2) @(posedge vif.CK_t);
              
              // Drive Preamble
              vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1; @(posedge vif.WCK_t);
              
              rdbi_en = (mode_reg_pc0[0][2] == 1'b1);
              
              for (int beat = 0; beat < 4; beat++) begin
                begin : mrr_rdbi_pc0
                  next_st = hbm4_pkg::process_dbi_word(mrr_data, last_read_state_pc0, rdbi_en);
                  read_data_pc0 = next_st[31:0];
                  read_dbi_pc0 = next_st[35:32];
                  read_valid_pc0 = 1;
                  last_read_state_pc0 = next_st;
                  
                  vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0;
                  @(negedge vif.WCK_t);
                  
                  next_st = hbm4_pkg::process_dbi_word(mrr_data, last_read_state_pc0, rdbi_en);
                  read_data_pc0 = next_st[31:0];
                  read_dbi_pc0 = next_st[35:32];
                  last_read_state_pc0 = next_st;
                  
                  vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1;
                  @(posedge vif.WCK_t);
                end
              end
              
              // Postamble
              vif.RDQS_t_PC0 <= 1; vif.RDQS_c_PC0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC0 <= 0; vif.RDQS_c_PC0 <= 1; @(posedge vif.WCK_t);
              read_valid_pc0 = 0;
            end
          join_none
        end
      end
      
      // Handle PC1
      if (dword_pc1.CMD == CMD_WR) begin

        int bank_idx;
        if (mr_programmed_pc0 != 20'hFFFFF || mr_programmed_pc1 != 20'hFFFFF) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: WRITE issued before all 20 Mode Registers were programmed!", $time);
        end

                
        bank_idx = {dword_pc1.BG, dword_pc1.BA};
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: WRITE PC1 to idle bank %0d!", $time, bank_idx);
        end
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: WRITE PC1 issued while in low-power state (%s)!", $time, power_state.name());
        end
        
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on WRITE PC1.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on WRITE PC1.", $time);
        end
        
        // Timing Check: tRCDWR
        if (($time - last_act_time[bank_idx]) < tRCDWR && last_act_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRCDWR violation on WRITE PC1 bank %0d. Expected %0t, got %0t", $time, bank_idx, tRCDWR, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tCCD (WR to WR)
        if (last_wr_time_pc1 != 0) begin
          time tccd_val;
          tccd_val = (dword_pc1.BG == last_wr_bg_pc1) ? tCCD_L : tCCD_S;
          if (($time - last_wr_time_pc1) < tccd_val) begin
          timing_violation_count++;
             $error("[%0t] HBM4_TIMING_ERROR: tCCD violation on WRITE PC1. Expected %0t, got %0t", $time, tccd_val, ($time - last_wr_time_pc1));
          end
        end
        
        // Timing Check: tRTW (RD to WR)
        if (($time - last_rd_time_pc1) < tRTW && last_rd_time_pc1 != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRTW violation on WRITE PC1. Expected %0t, got %0t", $time, tRTW, ($time - last_rd_time_pc1));
        end
        
        last_wr_time_pc1 <= $time;
        last_any_cmd_time <= $time;
        last_wr_bg_pc1 <= dword_pc1.BG;
        last_bank_wr_time[bank_idx] <= $time;
        
        // Execute Command
        begin
          automatic int b_idx = bank_idx;
          automatic int c_addr = dword_pc1.C_ADDR;
          automatic int addr = {dword_pc1.BG, dword_pc1.BA, active_row[bank_idx], dword_pc1.C_ADDR};
          automatic int dynamic_wl = (mode_reg_pc1[1] != 0) ? mode_reg_pc1[1][4:0] : 8;
          
          $display("[%0t] HBM4_MODEL: WRITE PC1 Bank %0d, Col %0h (WL=%0d)", $time, b_idx, c_addr, dynamic_wl);
          
          fork
            begin
              automatic logic [255:0] write_data;
              automatic logic wdbi_en = (mode_reg_pc1[0][1] == 1'b1);
              automatic logic dm_en = (mode_reg_pc1[0][3] == 1'b1);
              repeat(dynamic_wl) @(posedge vif.CK_t);
              
              // Skip write preamble (model starts 1 CK into the 2 CK preamble)
              repeat(2) begin
                @(posedge vif.WDQS_t_PC1);
                @(negedge vif.WDQS_t_PC1);
              end
              
              write_data = mem_array_pc1.exists(addr) ? mem_array_pc1[addr] : 256'h0;
              
              for (int beat = 0; beat < 4; beat++) begin
                automatic logic [31:0] dq_sampled;
                automatic logic [3:0]  dbi_sampled;
                
                @(posedge vif.WDQS_t_PC1);
                dq_sampled = vif.DQ_PC1;
                dbi_sampled = vif.DBI_PC1;
                for (int b = 0; b < 4; b++) begin
                  if (dm_en && dbi_sampled[b]) begin
                    // DM mode: mask this byte
                  end else begin
                    write_data[(beat*2)*32 + b*8 +: 8] = (wdbi_en && !dm_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                  end
                end
                
                @(negedge vif.WDQS_t_PC1);
                dq_sampled = vif.DQ_PC1;
                dbi_sampled = vif.DBI_PC1;
                for (int b = 0; b < 4; b++) begin
                  if (dm_en && dbi_sampled[b]) begin
                    // DM mode: mask this byte
                  end else begin
                    write_data[(beat*2+1)*32 + b*8 +: 8] = (wdbi_en && !dm_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                  end
                end
              end
              mem_array_pc1[addr] = write_data;
              ecc_array_pc1[addr] = ecc_encode(write_data);
              if (mode_reg_pc1[7][0]) loopback_data_pc1 = write_data;
              
              // Auto-Precharge: close bank after write recovery (tWR)
              if (c_addr[AP_BIT]) begin
                #(tWR);
                bank_state[b_idx] <= BANK_IDLE;
                last_pre_time[b_idx] <= $time;
                $display("[%0t] HBM4_MODEL: AUTO-PRECHARGE (WRA) PC1 Bank %0d", $time, b_idx);
              end
              
              last_read_state_pc1 = '0;
            end
          join_none
        end
      end
      else if (dword_pc1.CMD == CMD_RD) begin
                int bank_idx;
        bank_idx = {dword_pc1.BG, dword_pc1.BA};
        
        if (inject_ecc_error) begin
            $display("[%0t] HBM4_MODEL: INTERNAL ECC ERROR DETECTED on PC1. Asserting DERR.", $time);
            derr_out <= 1;
            derr_timer <= 4;
            inject_ecc_error <= 0;
            log_ecc_error(dword_pc1.BG, dword_pc1.BA, active_row[bank_idx], 4'hA);
            if (mode_reg_pc1[9][0]) begin
              $display("[%0t] HBM4_MODEL: ECC metadata enabled - syndrome=0xA, bank=%0d", $time, bank_idx);
            end
        end
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ PC1 to idle bank %0d!", $time, bank_idx);
        end
        if (power_state != PWR_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ PC1 issued while in low-power state (%s)!", $time, power_state.name());
        end
        
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on READ PC1.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
          timing_violation_count++;
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on READ PC1.", $time);
        end
        
        // Timing Check: tRCDRD
        if (($time - last_act_time[bank_idx]) < tRCDRD && last_act_time[bank_idx] != 0) begin
          timing_violation_count++;
          $error("[%0t] HBM4_TIMING_ERROR: tRCDRD violation on READ PC1 bank %0d. Expected %0t, got %0t", $time, bank_idx, tRCDRD, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tCCD (RD to RD)
        if (last_rd_time_pc1 != 0) begin
          time tccd_val;
          tccd_val = (dword_pc1.BG == last_rd_bg_pc1) ? tCCD_L : tCCD_S;
          if (($time - last_rd_time_pc1) < tccd_val) begin
          timing_violation_count++;
             $error("[%0t] HBM4_TIMING_ERROR: tCCD violation on READ PC1. Expected %0t, got %0t", $time, tccd_val, ($time - last_rd_time_pc1));
          end
        end
        
        // Timing Check: tWTR (WR to RD)
        if (last_wr_time_pc1 != 0) begin
          time twtr_val;
          twtr_val = (dword_pc1.BG == last_wr_bg_pc1) ? tWTR_L : tWTR_S;
          if (($time - last_wr_time_pc1) < twtr_val) begin
          timing_violation_count++;
             $error("[%0t] HBM4_TIMING_ERROR: tWTR violation on READ PC1. Expected %0t, got %0t", $time, twtr_val, ($time - last_wr_time_pc1));
          end
        end
        
        last_rd_time_pc1 <= $time;
        last_any_cmd_time <= $time;
        last_rd_bg_pc1 <= dword_pc1.BG;
        last_bank_rd_time[bank_idx] <= $time;
        
        // Execute Command
        begin
          fork
            begin
              logic [31:0] ui0_data;
              logic [31:0] ui1_data;
              logic [35:0] next_st;
              logic rdbi_en;
              int addr;
              logic [255:0] read_data_256;
              automatic int dynamic_rl = (mode_reg_pc1[2] != 0) ? mode_reg_pc1[2] : 14;
              automatic int b_idx = {dword_pc1.BG, dword_pc1.BA};
              addr = {dword_pc1.BG, dword_pc1.BA, active_row[b_idx], dword_pc1.C_ADDR};
              
              // Wait for RL (preamble starts 2 tCK early)
              repeat(dynamic_rl - 2) @(posedge vif.CK_t);
              
              // Drive Preamble (2 tCK = 4 WCK half-cycles, ends low for clean data posedge)
              vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1; @(posedge vif.WCK_t);
              
              rdbi_en = (mode_reg_pc1[0][2] == 1'b1);
              if (mode_reg_pc1[7][0])
                read_data_256 = loopback_data_pc1;
              else begin
                read_data_256 = mem_array_pc1.exists(addr) ? mem_array_pc1[addr] : 256'h0;
                if (ecc_array_pc1.exists(addr)) begin
                  ecc_result_t ecc_res;
                  ecc_res = ecc_decode(read_data_256, ecc_array_pc1[addr]);
                  if (ecc_res.sec_error) begin
                    read_data_256 = ecc_res.data;
                    mem_array_pc1[addr] = ecc_res.data;
                    ecc_sec_count++;
                    $display("[%0t] HBM4_ECC: SEC corrected on PC1 read addr=0x%0h", $time, addr);
                  end
                  if (ecc_res.ded_error) begin
                    ecc_ded_count++;
                    derr_out <= 1;
                    derr_timer <= 4;
                    log_ecc_error(dword_pc1.BG, dword_pc1.BA, active_row[b_idx], 4'hB);
                    $display("[%0t] HBM4_ECC: DED uncorrectable on PC1 read addr=0x%0h. DERR asserted.", $time, addr);
                  end
                end
              end
              
              for (int beat = 0; beat < 4; beat++) begin
                ui0_data = read_data_256[(beat*2)*32 +: 32];
                ui1_data = read_data_256[(beat*2+1)*32 +: 32];
                
                begin : rdbi_processing_pc1
                  next_st = hbm4_pkg::process_dbi_word(ui0_data, last_read_state_pc1, rdbi_en);
                  read_data_pc1 = next_st[31:0];
                  read_dbi_pc1 = next_st[35:32];
                  read_valid_pc1 = 1;
                  last_read_state_pc1 = next_st;
                  
                  vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0;
                  
                  @(negedge vif.WCK_t);
                  
                  next_st = hbm4_pkg::process_dbi_word(ui1_data, last_read_state_pc1, rdbi_en);
                  read_data_pc1 = next_st[31:0];
                  read_dbi_pc1 = next_st[35:32];
                  last_read_state_pc1 = next_st;
                  
                  vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1;
                  @(posedge vif.WCK_t);
                end
              end
              
              // Postamble (2 WCK pulses)
              vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1; @(posedge vif.WCK_t);
              read_valid_pc1 = 0;
              
              // Auto-Precharge: close bank after tRTP
              if (dword_pc1.C_ADDR[AP_BIT]) begin
                #(tRTP_L);
                bank_state[b_idx] <= BANK_IDLE;
                last_pre_time[b_idx] <= $time;
                $display("[%0t] HBM4_MODEL: AUTO-PRECHARGE (RDA) PC1 Bank %0d", $time, b_idx);
              end
            end
          join_none
        end
      end
      else if (dword_pc1.CMD == CMD_MRR) begin
        // Mode Register Read for PC1
        begin
          automatic int mr_idx = {dword_pc1.C, dword_pc1.BA};
          automatic logic [7:0] mr_val = (mr_idx == 4) ? simulated_temp[7:0] : mode_reg_pc1[mr_idx];
          automatic int dynamic_rl = (mode_reg_pc1[2] != 0) ? mode_reg_pc1[2] : 14;
          
          $display("[%0t] HBM4_MODEL: MRR PC1 MR%0d = 0x%02h (RL=%0d)", $time, mr_idx, mr_val, dynamic_rl);
          last_rd_time_pc1 <= $time;
          last_any_cmd_time <= $time;
          
          fork
            begin
              logic [31:0] mrr_data;
              logic [35:0] next_st;
              logic rdbi_en;
              
              mrr_data = {4{mr_val}};
              
              repeat(dynamic_rl - 2) @(posedge vif.CK_t);
              
              // Drive Preamble
              vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1; @(posedge vif.WCK_t);
              
              rdbi_en = (mode_reg_pc1[0][2] == 1'b1);
              
              for (int beat = 0; beat < 4; beat++) begin
                begin : mrr_rdbi_pc1
                  next_st = hbm4_pkg::process_dbi_word(mrr_data, last_read_state_pc1, rdbi_en);
                  read_data_pc1 = next_st[31:0];
                  read_dbi_pc1 = next_st[35:32];
                  read_valid_pc1 = 1;
                  last_read_state_pc1 = next_st;
                  
                  vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0;
                  @(negedge vif.WCK_t);
                  
                  next_st = hbm4_pkg::process_dbi_word(mrr_data, last_read_state_pc1, rdbi_en);
                  read_data_pc1 = next_st[31:0];
                  read_dbi_pc1 = next_st[35:32];
                  last_read_state_pc1 = next_st;
                  
                  vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1;
                  @(posedge vif.WCK_t);
                end
              end
              
              // Postamble
              vif.RDQS_t_PC1 <= 1; vif.RDQS_c_PC1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_PC1 <= 0; vif.RDQS_c_PC1 <= 1; @(posedge vif.WCK_t);
              read_valid_pc1 = 0;
            end
          join_none
        end
      end
    end
  end

  // =====================================================================
  // IEEE 1500 Wrapper Serial Port (WSP) Implementation
  // =====================================================================
  
  logic [7:0] wir; // Wrapper Instruction Register
  logic [31:0] wbr; // Wrapper Boundary Register
  logic wby; // Wrapper Bypass Register

  // Remap Register: {valid[36], bg[35:34], ba[33:30], faulty_row[29:15], spare_row[14:0]}
  localparam int REMAP_REG_WIDTH = 1 + 2 + 4 + ROW_WIDTH + ROW_WIDTH; // 37 bits
  logic [REMAP_REG_WIDTH-1:0] remap_reg;
  logic [REMAP_REG_WIDTH-1:0] remap_shift;
  
  logic [7:0] wir_shift;
  logic [31:0] wbr_shift;
  logic wby_shift;
  
  // WSO mux: instruction reg, bypass, remap, or boundary
  assign vif.WSO = (vif.SELECTWIR) ? wir_shift[0] :
                   (wir == 8'hFF) ? wby_shift :
                   (wir == 8'h02) ? remap_shift[0] : wbr_shift[0];

  always @(posedge vif.WRCK) begin
    if (!vif.RESET_n || !vif.WRST_n) begin
      wir <= 8'h00;
      wbr <= 32'h00000000;
      wby <= 1'b0;
      remap_reg <= '0;
      remap_shift <= '0;
      wir_shift <= 8'h00;
      wbr_shift <= 32'h00000000;
      wby_shift <= 1'b0;
      for (int i = 0; i < REMAP_TABLE_SIZE; i++) remap_table[i].valid <= 1'b0;
      remap_count <= 0;
    end else begin
      if (vif.SELECTWIR) begin
        // Instruction Register Access
        if (vif.CAPTUREWR) begin
          wir_shift <= wir;
        end else if (vif.SHIFTWR) begin
          wir_shift <= {vif.WSI, wir_shift[7:1]};
        end else if (vif.UPDATEWR) begin
          wir <= wir_shift;
        end
      end else begin
        // Data Register Access (Based on WIR)
        if (wir == 8'hFF) begin // Bypass
          if (vif.CAPTUREWR) begin
            wby_shift <= 1'b0;
          end else if (vif.SHIFTWR) begin
            wby_shift <= vif.WSI;
          end
        end else if (wir == 8'h02) begin // Remap Register
          if (vif.CAPTUREWR) begin
            remap_shift <= remap_reg;
          end else if (vif.SHIFTWR) begin
            remap_shift <= {vif.WSI, remap_shift[REMAP_REG_WIDTH-1:1]};
          end else if (vif.UPDATEWR) begin
            remap_reg <= remap_shift;
            // Program remap entry on update
            if (remap_shift[REMAP_REG_WIDTH-1] && remap_count < REMAP_TABLE_SIZE) begin
              remap_table[remap_count].valid <= 1'b1;
              remap_table[remap_count].bg <= remap_shift[REMAP_REG_WIDTH-2 -: 2];
              remap_table[remap_count].ba <= remap_shift[REMAP_REG_WIDTH-4 -: 4];
              remap_table[remap_count].faulty_row <= remap_shift[2*ROW_WIDTH-1 -: ROW_WIDTH];
              remap_table[remap_count].spare_row <= remap_shift[ROW_WIDTH-1:0];
              remap_count <= remap_count + 1;
              $display("[%0t] HBM4_REMAP: Programmed entry %0d: BG%0d BA%0d Row 0x%04h -> Spare 0x%04h",
                       $time, remap_count,
                       remap_shift[REMAP_REG_WIDTH-2 -: 2],
                       remap_shift[REMAP_REG_WIDTH-4 -: 4],
                       remap_shift[2*ROW_WIDTH-1 -: ROW_WIDTH],
                       remap_shift[ROW_WIDTH-1:0]);
            end
          end
        end else begin // Default to Boundary Register
          if (vif.CAPTUREWR) begin
            wbr_shift <= wbr;
          end else if (vif.SHIFTWR) begin
            wbr_shift <= {vif.WSI, wbr_shift[31:1]};
          end else if (vif.UPDATEWR) begin
            wbr <= wbr_shift;
          end
        end
      end
    end
  end

endmodule : hbm4_model
`endif
