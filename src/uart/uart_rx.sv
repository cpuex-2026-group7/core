`default_nettype none

module uart_rx #(CLK_PER_HALF_BIT = 5208) (
               output logic [7:0] rdata,
               output logic       rdata_ready,
               output logic       ferr,
               input wire         rxd,
               input wire         clk,
               input wire         rstn);

   localparam e_clk_bit = CLK_PER_HALF_BIT * 2 - 1;

   logic [7:0]    rxbuf;
   logic [1:0]    state;
   logic [31:0]   counter;
   logic          rst_ctr;

   logic          bit_end;
   logic          bit_mid;

   (* ASYNC_REG = "true" *) reg [2:0] rxd_sync;
   logic          rxd_clean;


   localparam s_idle = 2'd0;
   localparam s_start_bit = 2'd1;
   localparam s_data = 2'd2;
   localparam s_stop_bit = 2'd3;

   logic [2:0] s_bit_ctr;

   (* ASYNC_REG = "true"*) logic      rxd_sync_0;
   (* ASYNC_REG = "true" *) logic      rxd_sync_1;

   // synclonizer
   always @(posedge clk) begin
      if (~rstn) begin
         rxd_sync_0 <= 1'b1;
         rxd_sync_1 <= 1'b1;
      end else begin
         rxd_sync_0 <= rxd;
         rxd_sync_1 <= rxd_sync_0;
      end
   end

   always @(posedge clk) begin
      if (~rstn) begin
         rxd_sync <= 3'b111;
         rxd_clean <= 1'b1;
      end else begin
         rxd_sync <= {rxd_sync[1:0], rxd_sync_1};

         if(rxd_sync == 3'b111) begin
            rxd_clean <= 1'b1;
         end else if (rxd_sync == 3'b000) begin
            rxd_clean <= 1'b0;
         end
      end
   end

   // counter
   always @(posedge clk) begin
      if (~rstn) begin
         counter <= 32'b0;
         bit_end <= 1'b0;
         bit_mid <= 1'b0;
      end else begin
         // proceed counter
         if(counter == e_clk_bit || rst_ctr) begin
            counter <= 32'b0;
         end else begin
            counter <= counter + 32'd1;
         end

         // fire signal
         if(~rst_ctr && counter == CLK_PER_HALF_BIT) begin
            bit_mid <= 1'b1;
            bit_end <= 1'b0;
         end else if(~rst_ctr && counter == e_clk_bit) begin
            bit_mid <= 1'b0;
            bit_end <= 1'b1;
         end else begin
            bit_mid <= 1'b0;
            bit_end <= 1'b0;
         end
      end
   end

   // FSM
   always @(posedge clk) begin
      if (~rstn) begin
         rdata <= 8'b0;
         rdata_ready <= 1'b0;
         ferr <= 1'b0;
         state <= s_idle;
         rst_ctr <= 1'b0;
         rxbuf <= 8'b0;
         s_bit_ctr <= 3'd0;
      end else begin
         rst_ctr <= 1'b0;
         rdata_ready <= 1'b0;
         ferr <= 1'b0;

         case (state)
         s_idle: begin
            rst_ctr <= 1'b1;
            s_bit_ctr <= 3'd0;
            if(~rxd_clean) begin
               state <= s_start_bit;
            end
         end

         s_start_bit: begin
            if (bit_end) begin
               state <= s_data;
            end

            if (bit_mid && rxd_clean) begin
               state <= s_idle;
            end
         end

         s_data: begin
            if (bit_end) begin
               if (s_bit_ctr == 3'd7) begin
                  s_bit_ctr <= 3'd0;
                  state <= s_stop_bit;
               end else begin
                  s_bit_ctr <= s_bit_ctr + 3'd1;
               end
            end

            if (bit_mid) begin
               rxbuf <= {rxd_clean, rxbuf[7:1]};
            end
         end

         s_stop_bit: begin
            if(bit_mid) begin
               ferr <= ~rxd_clean;
               rdata <= rxbuf;
               rdata_ready <= 1'b1;
               state <= s_idle;
            end
         end

         endcase
      end
   end
   
endmodule
`default_nettype wire
