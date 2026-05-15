`ifndef HBM4_STACK_SV
`define HBM4_STACK_SV

import hbm4_pkg::*;

module hbm4_stack (
  hbm4_if channel_if [NUM_CHANNELS]
);

  // Generate block to instantiate 32 channels of memory
  generate
    genvar i;
    for (i = 0; i < NUM_CHANNELS; i++) begin : ch
      hbm4_model u_hbm4_model (
        .vif(channel_if[i].mem)
      );
    end
  endgenerate

endmodule

`endif
