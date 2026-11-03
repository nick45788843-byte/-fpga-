// A normal record observation cannot grant a namespace. A fresh verified journal
// commit, forward-only allocation, real global FE, and fresh proof are required.
// Each HELLO/resync uses a new operation cookie, never a reused prefix-only F0.
module a_namespace_control(input clk,rst_n,
 input boot_ready,text_settled,can_save,storage_busy,local_drained,
 output reg reserve_request,
 input save_accept,input [31:0] save_token,input save_done,input [31:0] saved_token,saved_sequence,input [7:0] save_error,
 input [31:0] allocator_next,output seed_valid,output [31:0] seed_token,input seed_ready,
 output borrow_valid,input borrow_ready,input [31:0] borrowed_token,
 input hello_accept,input [31:0] hello_token,
 input peer_online,peer_restart,link_trip,proof_valid,
 input ack_valid,input [31:0] ack_token,input [7:0] ack_index,ack_error,input ack_captured,
 output control_valid,output [63:0] control_header,
 output reg identity_known,session_ready,output reg [15:0] namespace_prefix,output reg [7:0] error_code);
localparam BOOT=0,WAIT_SAVE=1,SEED=2,COOKIE=3,SYNC=4,RUN=5,FAILED=6;
reg [2:0] state;reg owned,ack_seen,fresh_seen;reg [31:0] save_owner,reserved,cookie;
assign seed_valid=state==SEED&&local_drained;
assign seed_token={reserved[15:0],16'd1};
// F0 must reach B before its old producers can drain. The cookie itself owns
// no payload or hardware; the final SYNC -> RUN still requires all real credit.
assign borrow_valid=state==COOKIE&&identity_known;
assign control_valid=state==SYNC&&identity_known&&peer_online;
assign control_header={8'hf0,24'd0,cookie[7:0],cookie[15:8],cookie[23:16],cookie[31:24]};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=BOOT;owned<=0;save_owner<=0;reserved<=0;cookie<=0;
  ack_seen<=0;fresh_seen<=0;reserve_request<=0;identity_known<=0;session_ready<=0;namespace_prefix<=0;error_code<=0;end
 else begin
  reserve_request<=0;
  case(state)
   BOOT:if(boot_ready&&text_settled&&!storage_busy&&local_drained)begin
    if(!can_save)begin state<=FAILED;error_code<=8'h75;end
    else begin reserve_request<=1;state<=WAIT_SAVE;end
   end
   WAIT_SAVE:begin
    if(save_accept&&!owned)begin owned<=1;save_owner<=save_token;end
    if(save_done&&owned&&saved_token==save_owner)begin
     owned<=0;
     if(save_error!=0)begin state<=FAILED;error_code<=save_error;end
     else if(saved_sequence==0||saved_sequence>=32'h10000)begin state<=FAILED;error_code<=8'h48;end
     else if(saved_sequence[15:0]<=allocator_next[31:16])state<=BOOT;
     else begin reserved<=saved_sequence;state<=SEED;end
    end
   end
   SEED:if(seed_valid&&seed_ready)begin
    namespace_prefix<=reserved[15:0];identity_known<=1;session_ready<=0;
    ack_seen<=0;fresh_seen<=0;state<=COOKIE;
   end
   COOKIE:if(borrow_valid&&borrow_ready)begin
    cookie<=borrowed_token;ack_seen<=0;fresh_seen<=0;state<=SYNC;
   end
   SYNC:begin
    if(proof_valid)fresh_seen<=1;
    if(ack_valid&&ack_token==cookie&&ack_index==8'hfe&&ack_error==0&&!ack_captured)ack_seen<=1;
    if(ack_seen&&fresh_seen&&peer_online&&local_drained)begin session_ready<=1;error_code<=0;state<=RUN;end
   end
   RUN:if(allocator_next[31:16]!=namespace_prefix||allocator_next[15:0]>=16'hfff0)begin
    session_ready<=0;identity_known<=0;ack_seen<=0;fresh_seen<=0;state<=BOOT;
   end
   // Independent emergency/necessary saves can still run after a reservation
   // failure. A later actual accepted save may provide the fresh verified
   // sequence; no timer retries writes or declares success.
   FAILED:if(save_accept&&!owned)begin owned<=1;save_owner<=save_token;state<=WAIT_SAVE;end
  endcase
  if(identity_known&&(peer_restart||link_trip))begin
   session_ready<=0;ack_seen<=0;fresh_seen<=0;state<=COOKIE;
  end
  // A-only HELLO remains usable offline. It invalidates normal B permission and
  // queues a distinct global F0 before the next normal command may proceed.
  if(identity_known&&hello_accept&&hello_token[31:16]==namespace_prefix&&hello_token!=0&&
     (state==RUN||state==COOKIE||state==SYNC))begin
   cookie<=hello_token;session_ready<=0;ack_seen<=0;fresh_seen<=0;state<=SYNC;
  end
 end
end
endmodule
