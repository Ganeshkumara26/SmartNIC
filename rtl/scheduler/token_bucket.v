//============================================================================
// Token Bucket Rate Limiter
//============================================================================
// Implements a hardware token bucket for QoS bandwidth rate limiting.
// 
// ARCHITECTURE:
// ─────────────────────────────────────────────────────────────────────────
// Every REFRESH_PERIOD clock cycles, the bucket adds 'cfg_rate' tokens,
// up to a maximum capacity of 'cfg_burst'.
// 
// When the scheduler wants to transmit a 512-bit data beat (64 bytes),
// it consumes 1 token. If the bucket has 0 tokens, 'has_tokens' goes low,
// and the scheduler will temporarily block this queue from transmitting,
// effectively throttling its bandwidth and preventing starvation.
//
// 1 Token = 1 AXI-Stream Beat (64 Bytes)
//
// LEARNING NOTES:
// ─────────────────────────────────────────────────────────────────────────
// Rate = (cfg_rate / REFRESH_PERIOD) * Clock_Freq * 64 bytes
// Burst = cfg_burst * 64 bytes
//============================================================================

`timescale 1ns / 1ps

module token_bucket #(
    // Default: 100 cycles @ 100MHz = 1 microsecond refresh interval
    parameter REFRESH_PERIOD = 100 
)(
    input  wire         clk,
    input  wire         rst_n,
    
    // ── Configuration (from RISC-V) ───────────────────────────────────
    input  wire [31:0]  cfg_rate,   // Tokens added per refresh
    input  wire [31:0]  cfg_burst,  // Maximum tokens (bucket capacity)
    input  wire         cfg_enable, // If 0, bypasses the limiter (always has tokens)
    
    // ── Datapath Interface (to Scheduler) ─────────────────────────────
    output wire         has_tokens, // 1 = allowed to transmit
    input  wire         consume     // 1 = deduct 1 token
);

    // Internal state
    reg [31:0] token_count;
    reg [31:0] refresh_timer;

    // Has tokens if count > 0, OR if the limiter is disabled entirely
    assign has_tokens = (!cfg_enable) || (token_count > 0);

    always @(posedge clk) begin
        if (!rst_n) begin
            token_count   <= 32'd0;
            refresh_timer <= 32'd0;
        end else begin
            // 1. Handle Refresh Timer
            if (refresh_timer >= REFRESH_PERIOD - 1) begin
                refresh_timer <= 32'd0;
                
                // Add tokens, cap at cfg_burst
                if (!cfg_enable) begin
                    token_count <= 32'd0; // Keep at 0 when disabled
                end else if ((token_count + cfg_rate) > cfg_burst) begin
                    // If consuming on the exact same cycle it fills
                    if (consume) begin
                        token_count <= cfg_burst - 1'b1;
                    end else begin
                        token_count <= cfg_burst;
                    end
                end else begin
                    if (consume && token_count > 0) begin
                        token_count <= token_count + cfg_rate - 1'b1;
                    end else begin
                        token_count <= token_count + cfg_rate;
                    end
                end
            end else begin
                // Normal cycle (no refresh)
                refresh_timer <= refresh_timer + 1'b1;
                
                // 2. Handle Consumption
                if (consume && token_count > 0 && cfg_enable) begin
                    token_count <= token_count - 1'b1;
                end
            end
        end
    end

endmodule
