`timescale 1ns/1ps
//
// mac_rne_sat -- golden solution
//
module mac_rne_sat (
    input  logic               clk,
    input  logic               rst,       // synchronous, active-high
    input  logic               en,        // accumulate a*b this cycle
    input  logic               clr,       // clear accumulator this cycle
    input  logic               rd,        // request readout snapshot this cycle
    input  logic signed [7:0]  a,
    input  logic signed [7:0]  b,
    output logic signed [15:0] res,       // rounded + saturated snapshot
    output logic               res_valid, // 1-cycle pulse, one cycle after rd
    output logic               ovf        // sticky saturation flag
);

    // ------------------------------------------------------------------
    // Accumulator state
    // ------------------------------------------------------------------
    logic signed [27:0] acc;

    // Signed 8x8 product, sign-extended to the 28-bit accumulator width.
    logic signed [15:0] p;
    logic signed [27:0] p_ext;

    assign p     = a * b;
    assign p_ext = {{12{p[15]}}, p};

    // ------------------------------------------------------------------
    // Combinational readout pipeline: snapshot -> round (RNE) -> saturate
    // Always derived from the CURRENT (pre-update) value of acc, which is
    // exactly what "snapshot at end of cycle t-1" means.
    // ------------------------------------------------------------------
    logic signed [19:0] q;        // floor(acc / 256)
    logic        [7:0]  r;        // acc mod 256, 0..255 even for negative acc
    logic signed [20:0] rounded;  // extra headroom bit so q+1 can't wrap
    logic signed [15:0] sat_val;
    logic                sat_flag;

    always_comb begin
        q = acc[27:8];   // arithmetic-shift-right-by-8 == floor(acc/256)
        r = acc[7:0];    // low 8 bits, unsigned == acc mod 256

        rounded = q;     // sign-extend into 21 bits

        if (r == 8'd128) begin
            if (q[0])                 // tie: round to even
                rounded = rounded + 21'sd1;
        end else if (r > 8'd128) begin
            rounded = rounded + 21'sd1;
        end
        // r < 128: rounded stays q

        if (rounded > 21'sd32767) begin
            sat_val  = 16'sd32767;
            sat_flag = 1'b1;
        end else if (rounded < -21'sd32768) begin
            sat_val  = -16'sd32768;
            sat_flag = 1'b1;
        end else begin
            sat_val  = rounded[15:0];
            sat_flag = 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Sequential logic
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            acc       <= 28'sd0;
            res       <= 16'sd0;
            res_valid <= 1'b0;
            ovf       <= 1'b0;
        end else begin
            // Readout register: exactly one cycle after rd.
            if (rd) begin
                res       <= sat_val;
                res_valid <= 1'b1;
                if (sat_flag)
                    ovf <= 1'b1;      // set wins over same-cycle clr
                else if (clr)
                    ovf <= 1'b0;
                // else: ovf holds
            end else begin
                res_valid <= 1'b0;
                if (clr)
                    ovf <= 1'b0;
                // else: ovf holds, res holds (no assignment)
            end

            // Accumulator update.
            case ({clr, en})
                2'b00: acc <= acc;      // hold
                2'b01: acc <= acc + p_ext;
                2'b10: acc <= 28'sd0;
                2'b11: acc <= p_ext;    // clear-then-accumulate
            endcase
        end
    end

endmodule