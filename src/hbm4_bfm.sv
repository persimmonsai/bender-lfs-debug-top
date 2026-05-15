`ifndef HBM4_BFM_SV
`define HBM4_BFM_SV

import hbm4_pkg::*;

module hbm4_bfm (
  hbm4_if.ctrl vif
);

  // Initialize signals
  initial begin
    vif.CKE = 0;
    vif.AWORD = '0;
    vif.DWORD_PC0 = '0;
    vif.DWORD_PC1 = '0;
    vif.WDQS_t_pc0 = 0; vif.WDQS_c_pc0 = 1;
    vif.WDQS_t_pc1 = 0; vif.WDQS_c_pc1 = 1;
  end

  // BFM Tracking of Latencies
  int wl_pc0 = 8;
  int rl_pc0 = 10;
  int wl_pc1 = 8;
  int rl_pc1 = 10;
  

  // DQ and DBI Drivers
  logic [31:0] dq_pc0_drive = 'z;
  logic [7:0] mode_reg_pc0 [0:15];
  logic [7:0] mode_reg_pc1 [0:15];
  logic dq_pc0_en = 0;
  logic [3:0] dbi_pc0_drive = 'z;
  
  logic [31:0] dq_pc1_drive = 'z;
  logic pde_active_pc0 = 0;
  logic pde_active_pc1 = 0;




  // ------------------------------------------------------------------------'z;
  
  logic dq_pc1_en = 0;
  logic [3:0] dbi_pc1_drive = 'z;
  
  assign vif.DQ_PC0 = dq_pc0_en ? dq_pc0_drive : 'z;
  assign vif.DBI_PC0 = dq_pc0_en ? dbi_pc0_drive : 'z;
  
  assign vif.DQ_PC1 = dq_pc1_en ? dq_pc1_drive : 'z;
  assign vif.DBI_PC1 = dq_pc1_en ? dbi_pc1_drive : 'z;

  // AC DBI State Trackers for Writes
  logic [35:0] last_write_state_pc0 = '0; // {DBI[3:0], DQ[31:0]}
  logic [35:0] last_write_state_pc1 = '0;

  // Task for Power-up and Initialization
  task init();
    begin
      aword_t aword;
      dword_t dword;
      
      $display("[%0t] HBM4_BFM: Starting Initialization", $time);
      
      // Setup PDE state for when reset goes high
      aword = '0;
      aword.CMD = CMD_PDE;
      vif.AWORD <= aword;
      
      dword = '0;
      dword.CMD = CMD_NOP;
      vif.DWORD_PC0 <= dword;
      vif.DWORD_PC1 <= dword;

      // Initialize WDQS to static 0
      vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
      vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;

      wait (vif.RESET_n == 1);
      
      // Drive CKE high
      @(posedge vif.CK_t);
      vif.CKE <= 1;
      
      // Maintain PDE for a few cycles
      repeat(10) @(posedge vif.CK_t);
      
      // Exit PDE (Drive R[3:0] HIGH -> NOP)
      aword.CMD = CMD_NOP;
      vif.AWORD <= aword;
      $display("[%0t] HBM4_BFM: Exited PDE. Waiting tINIT5 (200ns)", $time);
      
      // Wait tINIT5 before first MRS
      #(200ns);
      
      // Auto-configure all 20 Mode Registers (MR0-MR19) for simulation
      $display("[%0t] HBM4_BFM: Auto-configuring Mode Registers MR0-MR19...", $time);
      for (int i = 0; i < 20; i++) begin
        automatic logic [7:0] mr_data;
        case (i)
          0: mr_data = 8'h04; // MR0: TCSR Enabled (OP[2]=1), DBI Disabled
          1: mr_data = 8'h06; // MR1: WL=6 nCK (OP[4:0]=6)
          2: mr_data = 8'h0E; // MR2: RL=14 nCK (OP[7:0]=14)
          3: mr_data = 8'h10; // MR3: WR=16 nCK (OP[7:0]=16)
          4: mr_data = 8'h22; // MR4: RAS=34 nCK (OP[7:0]=34)
          5: mr_data = 8'h08; // MR5: RTP=8 nCK (OP[3:0]=8)
          default: mr_data = 8'h00; // Other MRs default to 0
        endcase
        mode_register_set_pc0(i[4:0], mr_data);
        mode_register_set_pc1(i[4:0], mr_data);
        #(10ns);
      end
      
      $display("[%0t] HBM4_BFM: Initialization Complete", $time);
    end
  endtask


  // Task to issue ACTIVATE command
  task activate(input logic [1:0] bg, input logic [3:0] ba, input logic [14:0] row);
    begin
      aword_t aword;
      aword.CMD = CMD_ACT;
      aword.BG = bg;
      aword.BA = ba;
      aword.R_ADDR = row; // Simplified
      aword.R = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to issue PRECHARGE command
  task precharge(input logic [1:0] bg, input logic [3:0] ba);
    begin
      aword_t aword;
      aword.CMD = CMD_PRE;
      aword.BG = bg;
      aword.BA = ba;
      aword.R_ADDR = '0;
      aword.R = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to write data to PC0
  task automatic write_pc0(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col, input logic [255:0] data);
    dword_t dword;
    dword.CMD = CMD_WR;
    dword.BG = bg;
    dword.BA = ba;
    dword.C_ADDR = col;
    dword.C = 0;
    
    @(posedge vif.CK_t);
    vif.DWORD_PC0 <= dword;
    
    fork
      begin
        @(posedge vif.CK_t); // Wait for command to be on the bus
        repeat(wl_pc0 - 1) @(posedge vif.CK_t);
        
        // Four-pulse Preamble (4 WCK cycles = 2 tCK)
        for (int p = 0; p < 4; p++) begin
          vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
          @(negedge vif.WCK_t);
          vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
          @(posedge vif.WCK_t);
        end
        begin : wdbi_processing_pc0
          logic [31:0] ui0_data;
          logic [31:0] ui1_data;
          logic [35:0] next_st;
          logic wdbi_en;
          
          wdbi_en = (mode_reg_pc0[0][1] == 1'b1);
          
          for (int beat = 0; beat < 4; beat++) begin
            ui0_data = data[(beat*2)*32 +: 32];
            ui1_data = data[(beat*2+1)*32 +: 32];
            
            vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
            dq_pc0_en = 1;
            
            next_st = process_dbi_word(ui0_data, last_write_state_pc0, wdbi_en);
            dq_pc0_drive = next_st[31:0];
            dbi_pc0_drive = next_st[35:32];
            last_write_state_pc0 = next_st;
            
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
            
            next_st = process_dbi_word(ui1_data, last_write_state_pc0, wdbi_en);
            dq_pc0_drive = next_st[31:0];
            dbi_pc0_drive = next_st[35:32];
            last_write_state_pc0 = next_st;
            
            @(posedge vif.WCK_t);
          end
        end
        dq_pc0_en = 0;
        
        // Two-pulse Postamble (2 WCK cycles = 1 tCK)
        for (int p = 0; p < 2; p++) begin
          vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
          @(negedge vif.WCK_t);
          vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
          @(posedge vif.WCK_t);
        end
        vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
      end
    join_none
    
    @(posedge vif.CK_t);
    begin
      dword_t dword;
      dword.CMD = CMD_WR;
      dword.BG = bg;
      dword.BA = ba;
      dword.C_ADDR = col;
      dword.C = 0;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= dword;
      
      fork
        begin
          @(posedge vif.CK_t); // Wait for command to be on the bus
          repeat(wl_pc0 - 1) @(posedge vif.CK_t);
          
          // Two-pulse Preamble (2 WCK cycles = 1 tCK)
          for (int p = 0; p < 2; p++) begin
            vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
            @(posedge vif.WCK_t);
          end
          begin : wdbi_processing_pc0
            logic [31:0] ui0_data;
            logic [31:0] ui1_data;
            logic [35:0] next_st;
            logic wdbi_en;
            
            wdbi_en = (mode_reg_pc0[0][1] == 1'b1);
            
            for (int beat = 0; beat < 4; beat++) begin
              ui0_data = data[(beat*2)*32 +: 32];
              ui1_data = data[(beat*2+1)*32 +: 32];
              
              vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
              dq_pc0_en = 1;
              
              next_st = process_dbi_word(ui0_data, last_write_state_pc0, wdbi_en);
              dq_pc0_drive = next_st[31:0];
              dbi_pc0_drive = next_st[35:32];
              last_write_state_pc0 = next_st;
              
              @(negedge vif.WCK_t);
              vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
              
              next_st = process_dbi_word(ui1_data, last_write_state_pc0, wdbi_en);
              dq_pc0_drive = next_st[31:0];
              dbi_pc0_drive = next_st[35:32];
              last_write_state_pc0 = next_st;
              
              @(posedge vif.WCK_t);
            end
          end
          dq_pc0_en = 0;
          
          // Two-pulse Postamble (2 WCK cycles = 1 tCK)
          for (int p = 0; p < 2; p++) begin
            vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
            @(posedge vif.WCK_t);
          end
          vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= '0; // NOP
    end
  endtask

  // Task to read data from PC0
  task automatic read_pc0(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col);
    begin
      dword_t dword;
      dword.CMD = CMD_RD;
      dword.BG = bg;
      dword.BA = ba;
      dword.C_ADDR = col;
      dword.C = 0;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= dword;
      last_write_state_pc0 = '0;
      
      fork
        begin
          logic [255:0] read_data;
          @(posedge vif.CK_t); // Wait for command to be on the bus
          
          fork
            begin
              repeat(rl_pc0 - 2) @(posedge vif.CK_t);
              // Four-pulse Preamble (4 WCK cycles = 2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Toggle for 4 WCK cycles duration (2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Two-pulse Postamble (2 WCK cycles = 1 tCK)
              for (int p = 0; p < 2; p++) begin
                vif.WDQS_t_pc0 <= 1; vif.WDQS_c_pc0 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc0 <= 0; vif.WDQS_c_pc0 <= 1;
                @(posedge vif.WCK_t);
              end
            end
          join_none

          // Skip the RDQS 2-pulse preamble (2 WCK cycles = 1 tCK of toggling)
          repeat(2) begin
            @(posedge vif.RDQS_t_pc0);
            @(negedge vif.RDQS_t_pc0);
          end
          
          // We no longer wait for RL using CK, we just wait for RDQS edges!
          for (int beat = 0; beat < 4; beat++) begin
            automatic logic [31:0] dq_sampled;
            automatic logic [3:0]  dbi_sampled;
            
            @(posedge vif.RDQS_t_pc0);
            dq_sampled = vif.DQ_PC0;
            dbi_sampled = vif.DBI_PC0;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
            
            @(negedge vif.RDQS_t_pc0);
            dq_sampled = vif.DQ_PC0;
            dbi_sampled = vif.DBI_PC0;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2+1)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
          end
          $display("[%0t] HBM4_BFM: PC0 Burst Read Data = %0h", $time, read_data);
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= '0; // NOP
    end
  endtask

  // Task to write data to PC1
  task automatic write_pc1(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col, input logic [255:0] data);
    begin
      dword_t dword;
      dword.CMD = CMD_WR;
      dword.BG = bg;
      dword.BA = ba;
      dword.C_ADDR = col;
      dword.C = 0;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= dword;
      
      fork
        begin
          @(posedge vif.CK_t); // Wait for command to be on the bus
          repeat(wl_pc1 - 1) @(posedge vif.CK_t);
          
          // Four-pulse Preamble (4 WCK cycles = 2 tCK)
          for (int p = 0; p < 4; p++) begin
            vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
            @(posedge vif.WCK_t);
          end
          begin : wdbi_processing_pc1
            logic [31:0] ui0_data;
            logic [31:0] ui1_data;
            logic [35:0] next_st;
            logic wdbi_en;
            
            wdbi_en = (mode_reg_pc1[0][1] == 1'b1);
            
            for (int beat = 0; beat < 4; beat++) begin
              ui0_data = data[(beat*2)*32 +: 32];
              ui1_data = data[(beat*2+1)*32 +: 32];
              
              vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
              dq_pc1_en = 1;
              
              next_st = hbm4_pkg::process_dbi_word(ui0_data, last_write_state_pc1, wdbi_en);
              dq_pc1_drive = next_st[31:0];
              dbi_pc1_drive = next_st[35:32];
              last_write_state_pc1 = next_st;
              
              @(negedge vif.WCK_t);
              vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
              
              next_st = hbm4_pkg::process_dbi_word(ui1_data, last_write_state_pc1, wdbi_en);
              dq_pc1_drive = next_st[31:0];
              dbi_pc1_drive = next_st[35:32];
              last_write_state_pc1 = next_st;
              
              @(posedge vif.WCK_t);
            end
          end
          dq_pc1_en = 0;
          
          // Two-pulse Postamble (2 WCK cycles = 1 tCK)
          for (int p = 0; p < 2; p++) begin
            vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
            @(negedge vif.WCK_t);
            vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
            @(posedge vif.WCK_t);
          end
          vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= '0; // NOP
    end
  endtask

  // Task to read data from PC1
  task automatic read_pc1(input logic [1:0] bg, input logic [3:0] ba, input logic [5:0] col);
    begin
      dword_t dword;
      dword.CMD = CMD_RD;
      dword.BG = bg;
      dword.BA = ba;
      dword.C_ADDR = col;
      dword.C = 0;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= dword;
      last_write_state_pc1 = '0;
      
      fork
        begin
          logic [255:0] read_data;
          @(posedge vif.CK_t); // Wait for command to be on the bus
          
          fork
            begin
              repeat(rl_pc1 - 2) @(posedge vif.CK_t);
              // Four-pulse Preamble (4 WCK cycles = 2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Toggle for 4 WCK cycles duration (2 tCK)
              for (int beat = 0; beat < 4; beat++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
              
              // Two-pulse Postamble (2 WCK cycles = 1 tCK)
              for (int p = 0; p < 2; p++) begin
                vif.WDQS_t_pc1 <= 1; vif.WDQS_c_pc1 <= 0;
                @(negedge vif.WCK_t);
                vif.WDQS_t_pc1 <= 0; vif.WDQS_c_pc1 <= 1;
                @(posedge vif.WCK_t);
              end
            end
          join_none

          // Skip the RDQS 2-pulse preamble (2 WCK cycles = 1 tCK of toggling)
          repeat(2) begin
            @(posedge vif.RDQS_t_pc1);
            @(negedge vif.RDQS_t_pc1);
          end
          
          // We no longer wait for RL using CK, we just wait for RDQS edges!
          for (int beat = 0; beat < 4; beat++) begin
            automatic logic [31:0] dq_sampled;
            automatic logic [3:0]  dbi_sampled;
            
            @(posedge vif.RDQS_t_pc1);
            dq_sampled = vif.DQ_PC1;
            dbi_sampled = vif.DBI_PC1;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
            
            @(negedge vif.RDQS_t_pc1);
            dq_sampled = vif.DQ_PC1;
            dbi_sampled = vif.DBI_PC1;
            for (int b = 0; b < 4; b++) begin
              read_data[(beat*2+1)*32 + b*8 +: 8] = dbi_sampled[b] ? ~dq_sampled[b*8 +: 8] : dq_sampled[b*8 +: 8];
            end
          end
          $display("[%0t] HBM4_BFM: PC1 Burst Read Data = %0h", $time, read_data);
        end
      join_none
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= '0; // NOP
    end
  endtask

  // Task to issue REF command
  task refresh();
    begin
      aword_t aword;
      aword.CMD = CMD_REF;
      aword.BG = '0;
      aword.BA = '0;
      aword.R_ADDR = '0;
      aword.R = 0;
      
      @(posedge vif.CK_t);
      vif.AWORD <= aword;
      
      @(posedge vif.CK_t);
      vif.AWORD <= '0; // NOP
    end
  endtask

  // Task to issue MRS command to PC0
  task mode_register_set_pc0(input logic [4:0] mr_idx, input logic [7:0] data);
    begin
      dword_t dword;
      dword.CMD = CMD_MRS;
      dword.BA = mr_idx[3:0];
      dword.BG = data[7:6];
      dword.C_ADDR = data[5:0];
      dword.C = mr_idx[4];
      
      if (mr_idx == 5'h1 && data[4:0] != 0) wl_pc0 = data[4:0];
      if (mr_idx == 5'h2 && data != 0) rl_pc0 = data;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= dword;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC0 <= '0; // NOP
    end
  endtask

  // Task to issue MRS command to PC1
  task mode_register_set_pc1(input logic [4:0] mr_idx, input logic [7:0] data);
    begin
      dword_t dword;
      dword.CMD = CMD_MRS;
      dword.BA = mr_idx[3:0];
      dword.BG = data[7:6];
      dword.C_ADDR = data[5:0];
      dword.C = mr_idx[4];
      
      if (mr_idx == 5'h1 && data[4:0] != 0) wl_pc1 = data[4:0];
      if (mr_idx == 5'h2 && data != 0) rl_pc1 = data;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= dword;
      
      @(posedge vif.CK_t);
      vif.DWORD_PC1 <= '0; // NOP
    end
  endtask

endmodule
`endif
