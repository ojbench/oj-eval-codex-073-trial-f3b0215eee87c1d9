`timescale 1ns / 1ps

module cpu (
    input  wire        clk,
    input  wire        rst,
    input  wire        rdy_in,

    output reg  [31:0] inst_addr,
    input  wire [31:0] inst_rdata,

    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    output reg  [3:0]  mem_wmask,
    output reg         mem_we
);

    localparam [31:0] IO_UART_DATA = 32'h0003_0000;
    localparam [31:0] IO_UART_STAT = 32'h0003_0004;

    reg [31:0] pc;
    reg [31:0] regs [0:31];

    reg [31:0] instr;
    reg [4:0]  rd;
    reg [4:0]  rs1;
    reg [4:0]  rs2;
    reg [31:0] imm;
    reg [31:0] rs1_val;
    reg [31:0] rs2_val;
    reg [31:0] alu_res;
    reg [31:0] load_val;
    reg [31:0] next_pc;
    reg [2:0]  funct3;
    reg [6:0]  opcode;
    reg [6:0]  funct7;
    reg [31:0] load_word;
    reg [31:0] load_base;
    reg [31:0] store_data;

    reg        waiting_load;
    reg [4:0]  waiting_rd;
    reg        waiting_sign;
    reg [1:0]  waiting_size;
    reg        waiting_half_high;
    reg        waiting_unsigned;
    reg [31:0] waiting_addr;
    reg [31:0] waiting_next_pc;

    integer i;

    function [31:0] sext12;
        input [11:0] x;
        begin sext12 = {{20{x[11]}}, x}; end
    endfunction

    function [31:0] sext13;
        input [12:0] x;
        begin sext13 = {{19{x[12]}}, x}; end
    endfunction

    function [31:0] sext20;
        input [19:0] x;
        begin sext20 = {{12{x[19]}}, x}; end
    endfunction

    function [31:0] imm_i;
        input [31:0] ins;
        begin imm_i = sext12(ins[31:20]); end
    endfunction

    function [31:0] imm_u;
        input [31:0] ins;
        begin imm_u = {ins[31:12], 12'b0}; end
    endfunction

    function [31:0] imm_s;
        input [31:0] ins;
        begin imm_s = sext12({ins[31:25], ins[11:7]}); end
    endfunction

    function [31:0] imm_b;
        input [31:0] ins;
        begin imm_b = sext13({ins[31], ins[7], ins[30:25], ins[11:8], 1'b0}); end
    endfunction

    function [31:0] imm_j;
        input [31:0] ins;
        begin imm_j = {{11{ins[31]}}, ins[31], ins[19:12], ins[20], ins[30:21], 1'b0}; end
    endfunction

    function [31:0] mem_read_aligned;
        input [31:0] addr;
        input [31:0] data;
        input [2:0]  size;
        input        unsign;
        reg [1:0] off;
        reg [15:0] half;
        reg [7:0]  bytev;
        begin
            off = addr[1:0];
            case (size)
                3'b000: begin
                    bytev = (data >> (off * 8)) & 8'hff;
                    mem_read_aligned = unsign ? {24'b0, bytev} : {{24{bytev[7]}}, bytev};
                end
                3'b001: begin
                    half = (data >> {off[1], 4'b0}) & 16'hffff;
                    mem_read_aligned = unsign ? {16'b0, half} : {{16{half[15]}}, half};
                end
                default: mem_read_aligned = data;
            endcase
        end
    endfunction

    function [31:0] mem_write_aligned;
        input [31:0] addr;
        input [31:0] data;
        input [2:0]  size;
        reg [1:0] off;
        begin
            off = addr[1:0];
            case (size)
                3'b000: mem_write_aligned = {4{data[7:0]}} << (off * 8);
                3'b001: mem_write_aligned = {2{data[15:0]}} << {off[1], 4'b0};
                default: mem_write_aligned = data;
            endcase
        end
    endfunction

    task write_reg;
        input [4:0]  idx;
        input [31:0] value;
        begin
            if (idx != 0) regs[idx] <= value;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'b0;
            inst_addr <= 32'b0;
            mem_addr <= 32'b0;
            mem_wdata <= 32'b0;
            mem_wmask <= 4'b0;
            mem_we <= 1'b0;
            instr <= 32'b0;
            waiting_load <= 1'b0;
            waiting_rd <= 5'b0;
            waiting_sign <= 1'b0;
            waiting_size <= 2'b0;
            waiting_half_high <= 1'b0;
            waiting_unsigned <= 1'b0;
            waiting_addr <= 32'b0;
            waiting_next_pc <= 32'b0;
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
        end else if (rdy_in) begin
            mem_we <= 1'b0;
            mem_wmask <= 4'b0;

            if (waiting_load) begin
                load_word = mem_rdata;
                if (waiting_size == 2'b00) begin
                    load_val = mem_read_aligned(waiting_addr, load_word, 3'b000, waiting_unsigned);
                end else if (waiting_size == 2'b01) begin
                    load_val = mem_read_aligned(waiting_addr, load_word, 3'b001, waiting_unsigned);
                end else begin
                    load_val = load_word;
                end
                write_reg(waiting_rd, load_val);
                pc <= waiting_next_pc;
                waiting_load <= 1'b0;
            end else begin
                instr <= inst_rdata;
                opcode <= inst_rdata[6:0];
                rd <= inst_rdata[11:7];
                funct3 <= inst_rdata[14:12];
                rs1 <= inst_rdata[19:15];
                rs2 <= inst_rdata[24:20];
                funct7 <= inst_rdata[31:25];
                rs1_val <= regs[inst_rdata[19:15]];
                rs2_val <= regs[inst_rdata[24:20]];
                next_pc <= pc + 32'd4;

                case (inst_rdata[6:0])
                    7'b0110111: begin // LUI
                        write_reg(inst_rdata[11:7], imm_u(inst_rdata));
                        pc <= pc + 32'd4;
                    end
                    7'b0010111: begin // AUIPC
                        write_reg(inst_rdata[11:7], pc + imm_u(inst_rdata));
                        pc <= pc + 32'd4;
                    end
                    7'b1101111: begin // JAL
                        write_reg(inst_rdata[11:7], pc + 32'd4);
                        pc <= pc + imm_j(inst_rdata);
                    end
                    7'b1100111: begin // JALR
                        write_reg(inst_rdata[11:7], pc + 32'd4);
                        pc <= (regs[inst_rdata[19:15]] + imm_i(inst_rdata)) & ~32'b1;
                    end
                    7'b1100011: begin
                        case (inst_rdata[14:12])
                            3'b000: if (regs[inst_rdata[19:15]] == regs[inst_rdata[24:20]]) pc <= pc + imm_b(inst_rdata); else pc <= pc + 32'd4;
                            3'b001: if (regs[inst_rdata[19:15]] != regs[inst_rdata[24:20]]) pc <= pc + imm_b(inst_rdata); else pc <= pc + 32'd4;
                            3'b100: if ($signed(regs[inst_rdata[19:15]]) < $signed(regs[inst_rdata[24:20]])) pc <= pc + imm_b(inst_rdata); else pc <= pc + 32'd4;
                            3'b101: if ($signed(regs[inst_rdata[19:15]]) >= $signed(regs[inst_rdata[24:20]])) pc <= pc + imm_b(inst_rdata); else pc <= pc + 32'd4;
                            3'b110: if (regs[inst_rdata[19:15]] < regs[inst_rdata[24:20]]) pc <= pc + imm_b(inst_rdata); else pc <= pc + 32'd4;
                            3'b111: if (regs[inst_rdata[19:15]] >= regs[inst_rdata[24:20]]) pc <= pc + imm_b(inst_rdata); else pc <= pc + 32'd4;
                            default: pc <= pc + 32'd4;
                        endcase
                    end
                    7'b0000011: begin
                        load_base = regs[inst_rdata[19:15]] + imm_i(inst_rdata);
                        mem_addr <= load_base;
                        mem_we <= 1'b0;
                        mem_wmask <= 4'b0;
                        waiting_load <= 1'b1;
                        waiting_rd <= inst_rdata[11:7];
                        waiting_size <= inst_rdata[13:12];
                        waiting_unsigned <= inst_rdata[14];
                        waiting_addr <= load_base;
                        waiting_next_pc <= pc + 32'd4;
                    end
                    7'b0100011: begin
                        load_base = regs[inst_rdata[19:15]] + imm_s(inst_rdata);
                        store_data = mem_write_aligned(load_base, regs[inst_rdata[24:20]], inst_rdata[14:12]);
                        case (inst_rdata[14:12])
                            3'b000: begin mem_addr <= load_base; mem_wdata <= store_data; mem_we <= 1'b1; mem_wmask <= 4'b0001 << load_base[1:0]; end
                            3'b001: begin mem_addr <= load_base; mem_wdata <= store_data; mem_we <= 1'b1; mem_wmask <= load_base[1] ? 4'b1100 : 4'b0011; end
                            default: begin mem_addr <= load_base; mem_wdata <= store_data; mem_we <= 1'b1; mem_wmask <= 4'b1111; end
                        endcase
                        pc <= pc + 32'd4;
                    end
                    7'b0010011: begin
                        case (inst_rdata[14:12])
                            3'b000: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] + imm_i(inst_rdata));
                            3'b010: write_reg(inst_rdata[11:7], ($signed(regs[inst_rdata[19:15]]) < $signed(imm_i(inst_rdata))) ? 32'd1 : 32'd0);
                            3'b011: write_reg(inst_rdata[11:7], (regs[inst_rdata[19:15]] < imm_i(inst_rdata)) ? 32'd1 : 32'd0);
                            3'b100: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] ^ imm_i(inst_rdata));
                            3'b110: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] | imm_i(inst_rdata));
                            3'b111: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] & imm_i(inst_rdata));
                            3'b001: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] << inst_rdata[24:20]);
                            3'b101: begin
                                if (inst_rdata[30])
                                    write_reg(inst_rdata[11:7], $signed(regs[inst_rdata[19:15]]) >>> inst_rdata[24:20]);
                                else
                                    write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] >> inst_rdata[24:20]);
                            end
                        endcase
                        pc <= pc + 32'd4;
                    end
                    7'b0110011: begin
                        case ({inst_rdata[30], inst_rdata[14:12]})
                            4'b0_000: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] + regs[inst_rdata[24:20]]);
                            4'b1_000: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] - regs[inst_rdata[24:20]]);
                            4'b0_001: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] << regs[inst_rdata[24:20]][4:0]);
                            4'b0_010: write_reg(inst_rdata[11:7], ($signed(regs[inst_rdata[19:15]]) < $signed(regs[inst_rdata[24:20]])) ? 32'd1 : 32'd0);
                            4'b0_011: write_reg(inst_rdata[11:7], (regs[inst_rdata[19:15]] < regs[inst_rdata[24:20]]) ? 32'd1 : 32'd0);
                            4'b0_100: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] ^ regs[inst_rdata[24:20]]);
                            4'b0_101: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] >> regs[inst_rdata[24:20]][4:0]);
                            4'b1_101: write_reg(inst_rdata[11:7], $signed(regs[inst_rdata[19:15]]) >>> regs[inst_rdata[24:20]][4:0]);
                            4'b0_110: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] | regs[inst_rdata[24:20]]);
                            4'b0_111: write_reg(inst_rdata[11:7], regs[inst_rdata[19:15]] & regs[inst_rdata[24:20]]);
                        endcase
                        pc <= pc + 32'd4;
                    end
                    default: begin
                        pc <= pc + 32'd4;
                    end
                endcase
            end
            regs[0] <= 32'b0;
            inst_addr <= pc;
        end
    end
endmodule

// Compatibility wrappers for common lab/testbench interfaces.
module cpu_top(
    input wire clk,
    input wire rst,
    input wire rdy_in,
    output wire [31:0] inst_addr,
    input wire [31:0] inst_rdata,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    input wire [31:0] mem_rdata,
    output wire [3:0] mem_wmask,
    output wire mem_we
);
    cpu u_cpu(
        .clk(clk), .rst(rst), .rdy_in(rdy_in),
        .inst_addr(inst_addr), .inst_rdata(inst_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_wmask(mem_wmask), .mem_we(mem_we)
    );
endmodule

module top(
    input wire clk,
    input wire rst,
    input wire rdy_in,
    output wire [31:0] inst_addr,
    input wire [31:0] inst_rdata,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    input wire [31:0] mem_rdata,
    output wire [3:0] mem_wmask,
    output wire mem_we
);
    cpu_top u_top(.clk(clk), .rst(rst), .rdy_in(rdy_in), .inst_addr(inst_addr), .inst_rdata(inst_rdata), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_wmask(mem_wmask), .mem_we(mem_we));
endmodule
