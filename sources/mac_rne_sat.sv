`timescale 1ns/1ps

//
// mac_rne_sat -- golden implementation
// Implements docs/spec.md
//
module mac_rne_sat (
    input  logic               clk,
    input  logic               rst,
    input  logic               en,
    input  logic               clr,
    input  logic               rd,
    input  logic signed [7:0]   a,
    input  logic signed [7:0]   b,
    output logic signed [15:0]  res,
    output logic                res_valid,
    output logic                ovf
);

    // ============================================================
    // Step 2/3: 28-bit signed accumulator and signed product
    // ============================================================

    logic signed [27:0] acc;

    logic signed [15:0] product;
    logic signed [27:0] product_ext;

    assign product = a * b;

    // Sign-extend 16-bit product to 28 bits
    assign product_ext = {{12{product[15]}}, product};


    // ============================================================
    // Step 5/6/7/8:
    // Readout rounding and saturation
    //
    // q = floor(acc / 256)
    // r = acc - 256*q
    //
    // Since 256 = 2^8:
    // q = arithmetic right shift by 8
    // r = lower 8 bits
    // ============================================================

    logic signed [27:0] q;
    logic        [7:0]  remainder;
    logic               round_up;
    logic signed [27:0] rounded;

    logic               saturates;
    logic signed [15:0] saturated_result;

    always_comb begin

        // Arithmetic shift gives floor(acc / 256)
        q = acc >>> 8;

        // For a power-of-two divisor, lower 8 bits
        // give the required non-negative remainder.
        remainder = acc[7:0];

        // Round-half-to-even
        if (remainder > 8'd128) begin
            round_up = 1'b1;
        end
        else if (remainder < 8'd128) begin
            round_up = 1'b0;
        end
        else begin
            // Tie: increment only when q is odd
            round_up = q[0];
        end

        // Apply rounding before saturation
        rounded = q;

        if (round_up)
            rounded = q + 28'sd1;


        // ========================================================
        // Step 8: Saturation AFTER rounding
        // ========================================================

        if (rounded > 28'sd32767) begin

            saturated_result = 16'sd32767;
            saturates = 1'b1;

        end
        else if (rounded < -28'sd32768) begin

            saturated_result = -16'sd32768;
            saturates = 1'b1;

        end
        else begin

            saturated_result = rounded[15:0];
            saturates = 1'b0;

        end

    end


    // ============================================================
    // Step 9/10/11:
    // Sequential accumulator, readout, res_valid and ovf
    // ============================================================

    always_ff @(posedge clk) begin

        // ========================================================
        // Step 11: synchronous active-high reset
        // ========================================================

        if (rst) begin

            acc       <= 28'sd0;
            res       <= 16'sd0;
            res_valid <= 1'b0;
            ovf       <= 1'b0;

        end
        else begin

            // ====================================================
            // Step 10: res_valid is one cycle after rd
            // ====================================================

            res_valid <= rd;


            // ====================================================
            // Step 9: accumulator update
            //
            // clr en
            //  0   0 -> hold
            //  0   1 -> acc + product
            //  1   0 -> 0
            //  1   1 -> product
            // ====================================================

            if (clr) begin

                if (en)
                    acc <= product_ext;
                else
                    acc <= 28'sd0;

            end
            else if (en) begin

                acc <= acc + product_ext;

            end


            // ====================================================
            // Step 8/9:
            // Readout uses OLD acc value.
            //
            // Because acc is updated using nonblocking assignment,
            // the combinational rounded/saturated result above is
            // based on the accumulator value before this edge.
            // ====================================================

            if (rd) begin

                res <= saturated_result;

            end


            // ====================================================
            // Step 9:
            // Sticky overflow flag
            //
            // Saturating readout has priority over clr.
            // ====================================================

            if (rd && saturates) begin

                ovf <= 1'b1;

            end
            else if (clr) begin

                ovf <= 1'b0;

            end

        end

    end

endmodule
