`timescale 1ns/1ps

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

    logic signed [27:0] acc;

    logic signed [15:0] product;
    logic signed [27:0] product_ext;

    assign product = a * b;
    assign product_ext = {{12{product[15]}}, product};

    logic signed [27:0] q;
    logic        [7:0]  remainder;
    logic               round_up;
    logic signed [27:0] rounded;

    logic               saturates;
    logic signed [15:0] saturated_result;

    always_comb begin
        q = acc >>> 8;
        remainder = acc[7:0];

        if (remainder > 8'd128)
            round_up = 1'b1;
        else if (remainder < 8'd128)
            round_up = 1'b0;
        else
            round_up = q[0];

        rounded = q;

        if (round_up)
            rounded = q + 28'sd1;

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

    always_ff @(posedge clk) begin
        if (rst) begin
            acc       <= 28'sd0;
            res       <= 16'sd0;
            res_valid <= 1'b0;
            ovf       <= 1'b0;
        end
        else begin
            res_valid <= rd;

            if (clr) begin
                if (en)
                    acc <= product_ext;
                else
                    acc <= 28'sd0;
            end
            else if (en) begin
                acc <= acc + product_ext;
            end

            if (rd)
                res <= saturated_result;

            if (rd && saturates)
                ovf <= 1'b1;
            else if (clr)
                ovf <= 1'b0;
        end
    end

endmodule
