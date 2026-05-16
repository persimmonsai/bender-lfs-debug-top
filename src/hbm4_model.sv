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

  // Timing Trackers
  time last_act_time [NUM_BANKS];
  time last_pre_time [NUM_BANKS];
  time last_bank_wr_time [NUM_BANKS];
  time last_bank_rd_time [NUM_BANKS];

  // Global PC Trackers
  time last_rd_time_pc0 = 0, last_wr_time_pc0 = 0;
  logic [1:0] last_rd_bg_pc0 = 0, last_wr_bg_pc0 = 0;
  
  time last_rd_time_pc1 = 0, last_wr_time_pc1 = 0;
  logic [1:0] last_rd_bg_pc1 = 0, last_wr_bg_pc1 = 0;

  // Refresh and MRS Trackers
  time last_ref_time = 0;
  time last_refpb_time [NUM_BANKS];
  time last_mrs_time = 0;

  // DBI Trackers
  logic [35:0] last_read_state_pc0 = '0; // {DBI[3:0], DQ[31:0]}
  logic [35:0] last_read_state_pc1 = '0;

  logic pde_active_pc0 = 0;
  logic pde_active_pc1 = 0;
  logic [14:0] active_row_pc0 [NUM_BANKS];
  logic [14:0] active_row_pc1 [NUM_BANKS];

  // Mode Registers
  logic [7:0] mode_reg_pc0 [20];
  logic [19:0] mr_programmed_pc0 = 0;
  logic [7:0] mode_reg_pc1 [20];
  logic [19:0] mr_programmed_pc1 = 0;

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

  initial begin
    read_valid_pc0 = 0;
    read_valid_pc1 = 0;
    read_data_pc0 = 32'hz;
    read_data_pc1 = 32'hz;
    read_dbi_pc0  = 4'hz;
    read_dbi_pc1  = 4'hz;
    vif.RDQS_t_pc0 = 0;
    vif.RDQS_c_pc0 = 1;
    vif.RDQS_t_pc1 = 0;
    vif.RDQS_c_pc1 = 1;
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
      end
    end else begin
      // Decode AWORD command
      aword_t aword;
      dword_t dword_pc0;
      dword_t dword_pc1;
      aword = vif.AWORD;
      dword_pc0 = dword_t'(vif.DWORD_PC0);
      dword_pc1 = dword_t'(vif.DWORD_PC1);
      
      // Initialization Sequence Checking
      if (init_state != INIT_DONE) begin
        if (init_state == INIT_WAIT_PDE) begin
          if (aword.CMD == CMD_PDE && dword_pc0.CMD == CMD_NOP && dword_pc1.CMD == CMD_NOP) begin
            init_state = INIT_WAIT_MRS;
            pde_entry_time = $time;
            $display("[%0t] HBM4_MODEL: Entered PDE state during initialization.", $time);
          end else begin
            $error("[%0t] HBM4_PROTOCOL_ERROR: Command must be PDE and DWORD NOP upon first CK toggle after reset! Got AWORD=%0h", $time, aword.CMD);
          end
        end else if (init_state == INIT_WAIT_MRS) begin
          if (aword.CMD == CMD_NOP && dword_pc0.CMD == CMD_NOP && dword_pc1.CMD == CMD_NOP) begin
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
        mode_reg_pc0[mr_idx] <= {dword_pc0.BG, dword_pc0.C_ADDR};
        mr_programmed_pc0[mr_idx] <= 1;
        $display("[%0t] HBM4_MODEL: Programmed PC0 MR%0d", $time, mr_idx);
        last_mrs_time <= $time;
      end
      if (dword_pc1.CMD == CMD_MRS) begin
        automatic int mr_idx = {dword_pc1.C, dword_pc1.BA};
        mode_reg_pc1[mr_idx] <= {dword_pc1.BG, dword_pc1.C_ADDR};
        mr_programmed_pc1[mr_idx] <= 1;
        last_mrs_time <= $time;
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
        if (bank_state[bank_idx] != BANK_IDLE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: ACTIVATE to already active bank %0d!", $time, bank_idx);
        end
        
        // Refresh Starvation Check
        if (($time - last_ref_time) > tREFI && last_ref_time != 0) begin
           $error("[%0t] HBM4_PROTOCOL_ERROR: Refresh Starvation! tREFI violation.", $time);
        end
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on ACTIVATE. Command issued during refresh.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on ACTIVATE. Command issued too soon after MRS.", $time);
        end
        
        // Timing Check: tRP
        if (($time - last_pre_time[bank_idx]) < tRP && last_pre_time[bank_idx] != 0) begin
          $error("[%0t] HBM4_TIMING_ERROR: tRP violation on bank %0d. Expected %0t, got %0t", $time, bank_idx, tRP, ($time - last_pre_time[bank_idx]));
        end
        
        // Timing Check: tRC
        if (($time - last_act_time[bank_idx]) < tRC && last_act_time[bank_idx] != 0) begin
          $error("[%0t] HBM4_TIMING_ERROR: tRC violation on bank %0d. Expected %0t, got %0t", $time, bank_idx, tRC, ($time - last_act_time[bank_idx]));
        end

        // Execute Command
        bank_state[bank_idx] <= BANK_ACTIVE;
        active_row[bank_idx] <= aword.R_ADDR; // Assuming R_ADDR captures the whole row for now
        last_act_time[bank_idx] <= $time;
        $display("[%0t] HBM4_MODEL: ACTIVATE Bank %0d, Row %0h", $time, bank_idx, aword.R_ADDR);
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
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on PRECHARGE.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on PRECHARGE.", $time);
        end
        
        // Timing Check: tRAS
        if (($time - last_act_time[bank_idx]) < tRAS && last_act_time[bank_idx] != 0) begin
          $error("[%0t] HBM4_TIMING_ERROR: tRAS violation on bank %0d. Expected %0t, got %0t", $time, bank_idx, tRAS, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tWR
        if (($time - last_bank_wr_time[bank_idx]) < tWR && last_bank_wr_time[bank_idx] != 0) begin
          $error("[%0t] HBM4_TIMING_ERROR: tWR violation on PRECHARGE bank %0d. Expected %0t, got %0t", $time, bank_idx, tWR, ($time - last_bank_wr_time[bank_idx]));
        end
        
        // Timing Check: tRTP
        if (($time - last_bank_rd_time[bank_idx]) < tRTP && last_bank_rd_time[bank_idx] != 0) begin
          $error("[%0t] HBM4_TIMING_ERROR: tRTP violation on PRECHARGE bank %0d. Expected %0t, got %0t", $time, bank_idx, tRTP, ($time - last_bank_rd_time[bank_idx]));
        end
        
        // Execute Command
        bank_state[bank_idx] <= BANK_IDLE;
        last_pre_time[bank_idx] <= $time;
        $display("[%0t] HBM4_MODEL: PRECHARGE Bank %0d", $time, bank_idx);
      end
      else if (aword.CMD == CMD_PREA) begin
        // Check tRFC
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on PREA.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on PREA.", $time);
        end
        
        for (int i = 0; i < NUM_BANKS; i++) begin
          if (bank_state[i] == BANK_ACTIVE) begin
            // Timing Check: tRAS
            if (($time - last_act_time[i]) < tRAS && last_act_time[i] != 0) begin
              $error("[%0t] HBM4_TIMING_ERROR: tRAS violation on PREA bank %0d. Expected %0t, got %0t", $time, i, tRAS, ($time - last_act_time[i]));
            end
            // Timing Check: tWR
            if (($time - last_bank_wr_time[i]) < tWR && last_bank_wr_time[i] != 0) begin
              $error("[%0t] HBM4_TIMING_ERROR: tWR violation on PREA bank %0d. Expected %0t, got %0t", $time, i, tWR, ($time - last_bank_wr_time[i]));
            end
            // Timing Check: tRTP
            if (($time - last_bank_rd_time[i]) < tRTP && last_bank_rd_time[i] != 0) begin
              $error("[%0t] HBM4_TIMING_ERROR: tRTP violation on PREA bank %0d. Expected %0t, got %0t", $time, i, tRTP, ($time - last_bank_rd_time[i]));
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
           $error("[%0t] HBM4_TIMING_ERROR: tRFCpb violation on REFpb bank %0d.", $time, bank_idx);
        end
        // Also respect all-bank refresh
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on REFpb.", $time);
        end

        last_refpb_time[bank_idx] <= $time;
        $display("[%0t] HBM4_MODEL: PER-BANK REFRESH Bank %0d", $time, bank_idx);
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
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on REF.", $time);
        end
        last_ref_time <= $time;
        $display("[%0t] HBM4_MODEL: ALL-BANK REFRESH", $time);
      end
      end // End of initialized condition
    end
  end

  initial begin
    read_valid_pc0 = 0;
    read_valid_pc1 = 0;
    read_data_pc0 = 32'hz;
    read_data_pc1 = 32'hz;
    read_dbi_pc0  = 4'hz;
    read_dbi_pc1  = 4'hz;
    vif.RDQS_t_pc0 = 0;
    vif.RDQS_c_pc0 = 1;
    vif.RDQS_t_pc1 = 0;
    vif.RDQS_c_pc1 = 1;
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
        
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on WRITE PC0.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on WRITE PC0.", $time);
        end
        
        // Timing Check: tRCD
        if (($time - last_act_time[bank_idx]) < tRCD && last_act_time[bank_idx] != 0) begin
          $error("[%0t] HBM4_TIMING_ERROR: tRCD violation on WRITE PC0 bank %0d. Expected %0t, got %0t", $time, bank_idx, tRCD, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tCCD (WR to WR)
        if (last_wr_time_pc0 != 0) begin
          time tccd_val;
          tccd_val = (dword_pc0.BG == last_wr_bg_pc0) ? tCCD_L : tCCD_S;
          if (($time - last_wr_time_pc0) < tccd_val) begin
             $error("[%0t] HBM4_TIMING_ERROR: tCCD violation on WRITE PC0. Expected %0t, got %0t", $time, tccd_val, ($time - last_wr_time_pc0));
          end
        end
        
        // Timing Check: tRTW (RD to WR)
        if (($time - last_rd_time_pc0) < tRTW && last_rd_time_pc0 != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tRTW violation on WRITE PC0. Expected %0t, got %0t", $time, tRTW, ($time - last_rd_time_pc0));
        end
        
        last_wr_time_pc0 <= $time;
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
              // WDBI is controlled by MR0 OP[1]
              automatic logic wdbi_en = (mode_reg_pc0[0][1] == 1'b1);
              repeat(dynamic_wl) @(posedge vif.CK_t);
              
              for (int beat = 0; beat < 4; beat++) begin
                automatic logic [31:0] dq_sampled;
                automatic logic [3:0]  dbi_sampled;
                
                @(posedge vif.WDQS_t_pc0);
                dq_sampled = vif.DQ_PC0;
                dbi_sampled = vif.DBI_PC0;
                for (int b = 0; b < 4; b++) begin
                  write_data[(beat*2)*32 + b*8 +: 8] = (wdbi_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                end
                
                @(negedge vif.WDQS_t_pc0);
                dq_sampled = vif.DQ_PC0;
                dbi_sampled = vif.DBI_PC0;
                for (int b = 0; b < 4; b++) begin
                  write_data[(beat*2+1)*32 + b*8 +: 8] = (wdbi_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                end
              end
              mem_array_pc0[addr] = write_data;
              
              // Reset Read DBI state on write-to-read turnaround (as per spec)
              last_read_state_pc0 = '0;
            end
          join_none
        end
      end
      else if (dword_pc0.CMD == CMD_RD) begin
                int bank_idx;
        bank_idx = {dword_pc0.BG, dword_pc0.BA};
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ PC0 to idle bank %0d!", $time, bank_idx);
        end
        
        // Refresh Cycle Check
        if (($time - last_ref_time) < tRFC && last_ref_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tRFC violation on READ PC0.", $time);
        end
        // tMOD Check
        if (($time - last_mrs_time) < tMOD && last_mrs_time != 0) begin
           $error("[%0t] HBM4_TIMING_ERROR: tMOD violation on READ PC0.", $time);
        end
        
        // Timing Check: tRCD
        if (($time - last_act_time[bank_idx]) < tRCD && last_act_time[bank_idx] != 0) begin
          $error("[%0t] HBM4_TIMING_ERROR: tRCD violation on READ PC0 bank %0d. Expected %0t, got %0t", $time, bank_idx, tRCD, ($time - last_act_time[bank_idx]));
        end
        
        // Timing Check: tCCD (RD to RD)
        if (last_rd_time_pc0 != 0) begin
          time tccd_val;
          tccd_val = (dword_pc0.BG == last_rd_bg_pc0) ? tCCD_L : tCCD_S;
          if (($time - last_rd_time_pc0) < tccd_val) begin
             $error("[%0t] HBM4_TIMING_ERROR: tCCD violation on READ PC0. Expected %0t, got %0t", $time, tccd_val, ($time - last_rd_time_pc0));
          end
        end
        
        // Timing Check: tWTR (WR to RD)
        if (last_wr_time_pc0 != 0) begin
          time twtr_val;
          twtr_val = (dword_pc0.BG == last_wr_bg_pc0) ? tWTR_L : tWTR_S;
          if (($time - last_wr_time_pc0) < twtr_val) begin
             $error("[%0t] HBM4_TIMING_ERROR: tWTR violation on READ PC0. Expected %0t, got %0t", $time, twtr_val, ($time - last_wr_time_pc0));
          end
        end
        
        last_rd_time_pc0 <= $time;
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
              
              // Drive Preamble (4 WCK pulses)
              vif.RDQS_t_pc0 <= 0; vif.RDQS_c_pc0 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_pc0 <= 1; vif.RDQS_c_pc0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_pc0 <= 0; vif.RDQS_c_pc0 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_pc0 <= 1; vif.RDQS_c_pc0 <= 0; @(negedge vif.WCK_t);
              
              rdbi_en = (mode_reg_pc0[0][2] == 1'b1);
              read_data_256 = mem_array_pc0.exists(addr) ? mem_array_pc0[addr] : 256'h0;
              
              for (int beat = 0; beat < 4; beat++) begin
                ui0_data = read_data_256[(beat*2)*32 +: 32];
                ui1_data = read_data_256[(beat*2+1)*32 +: 32];
                
                begin : rdbi_processing_pc0
                  next_st = hbm4_pkg::process_dbi_word(ui0_data, last_read_state_pc0, rdbi_en);
                  read_data_pc0 = next_st[31:0];
                  read_dbi_pc0 = next_st[35:32];
                  read_valid_pc0 = 1;
                  last_read_state_pc0 = next_st;
                  
                  vif.RDQS_t_pc0 <= 1; vif.RDQS_c_pc0 <= 0;
                  
                  @(negedge vif.WCK_t);
                  
                  next_st = hbm4_pkg::process_dbi_word(ui1_data, last_read_state_pc0, rdbi_en);
                  read_data_pc0 = next_st[31:0];
                  read_dbi_pc0 = next_st[35:32];
                  last_read_state_pc0 = next_st;
                  
                  vif.RDQS_t_pc0 <= 0; vif.RDQS_c_pc0 <= 1;
                  @(posedge vif.WCK_t);
                end
              end
              
              // Postamble (2 WCK pulses)
              vif.RDQS_t_pc0 <= 1; vif.RDQS_c_pc0 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_pc0 <= 0; vif.RDQS_c_pc0 <= 1; @(posedge vif.WCK_t);
              read_valid_pc0 = 0;
            end
          join_none
        end
      end
      
      // Handle PC1
      if (dword_pc1.CMD == CMD_WR) begin

        int bank_idx;
        if (mr_programmed_pc0 != 20'hFFFFF || mr_programmed_pc1 != 20'hFFFFF) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ issued before all 20 Mode Registers were programmed!", $time);
        end

                
        bank_idx = {dword_pc1.BG, dword_pc1.BA};
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: WRITE PC1 to idle bank %0d!", $time, bank_idx);
        end
        
        last_wr_time_pc1 <= $time;
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
              repeat(dynamic_wl) @(posedge vif.CK_t);
              
              for (int beat = 0; beat < 4; beat++) begin
                automatic logic [31:0] dq_sampled;
                automatic logic [3:0]  dbi_sampled;
                
                @(posedge vif.WDQS_t_pc1);
                dq_sampled = vif.DQ_PC1;
                dbi_sampled = vif.DBI_PC1;
                for (int b = 0; b < 4; b++) begin
                  write_data[(beat*2)*32 + b*8 +: 8] = (wdbi_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                end
                
                @(negedge vif.WDQS_t_pc1);
                dq_sampled = vif.DQ_PC1;
                dbi_sampled = vif.DBI_PC1;
                for (int b = 0; b < 4; b++) begin
                  write_data[(beat*2+1)*32 + b*8 +: 8] = (wdbi_en && dbi_sampled[b]) ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
                end
              end
              mem_array_pc1[addr] = write_data;
              last_read_state_pc1 = '0;
            end
          join_none
        end
      end
      else if (dword_pc1.CMD == CMD_RD) begin
                int bank_idx;
        bank_idx = {dword_pc1.BG, dword_pc1.BA};
        
        // Protocol Check
        if (bank_state[bank_idx] != BANK_ACTIVE) begin
          $error("[%0t] HBM4_PROTOCOL_ERROR: READ PC1 to idle bank %0d!", $time, bank_idx);
        end
        
        last_rd_time_pc1 <= $time;
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
              
              // Drive Preamble (4 WCK pulses)
              vif.RDQS_t_pc1 <= 0; vif.RDQS_c_pc1 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_pc1 <= 1; vif.RDQS_c_pc1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_pc1 <= 0; vif.RDQS_c_pc1 <= 1; @(posedge vif.WCK_t);
              vif.RDQS_t_pc1 <= 1; vif.RDQS_c_pc1 <= 0; @(negedge vif.WCK_t);
              
              rdbi_en = (mode_reg_pc1[0][2] == 1'b1);
              read_data_256 = mem_array_pc1.exists(addr) ? mem_array_pc1[addr] : 256'h0;
              
              for (int beat = 0; beat < 4; beat++) begin
                ui0_data = read_data_256[(beat*2)*32 +: 32];
                ui1_data = read_data_256[(beat*2+1)*32 +: 32];
                
                begin : rdbi_processing_pc1
                  next_st = hbm4_pkg::process_dbi_word(ui0_data, last_read_state_pc1, rdbi_en);
                  read_data_pc1 = next_st[31:0];
                  read_dbi_pc1 = next_st[35:32];
                  read_valid_pc1 = 1;
                  last_read_state_pc1 = next_st;
                  
                  vif.RDQS_t_pc1 <= 1; vif.RDQS_c_pc1 <= 0;
                  
                  @(negedge vif.WCK_t);
                  
                  next_st = hbm4_pkg::process_dbi_word(ui1_data, last_read_state_pc1, rdbi_en);
                  read_data_pc1 = next_st[31:0];
                  read_dbi_pc1 = next_st[35:32];
                  last_read_state_pc1 = next_st;
                  
                  vif.RDQS_t_pc1 <= 0; vif.RDQS_c_pc1 <= 1;
                  @(posedge vif.WCK_t);
                end
              end
              
              // Postamble (2 WCK pulses)
              vif.RDQS_t_pc1 <= 1; vif.RDQS_c_pc1 <= 0; @(negedge vif.WCK_t);
              vif.RDQS_t_pc1 <= 0; vif.RDQS_c_pc1 <= 1; @(posedge vif.WCK_t);
              read_valid_pc1 = 0;
            end
          join_none
        end
      end
    end
  end

  // Continuous assignments for driving read data
  assign vif.DQ_PC0 = read_valid_pc0 ? read_data_pc0 : 32'hz;
  assign vif.DBI_PC0 = read_valid_pc0 ? read_dbi_pc0 : 4'hz;
  
  assign vif.DQ_PC1 = read_valid_pc1 ? read_data_pc1 : 32'hz;
  assign vif.DBI_PC1 = read_valid_pc1 ? read_dbi_pc1 : 4'hz;

endmodule : hbm4_model
`endif
