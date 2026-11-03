// Reply fairness must advance even if a CRC-qualified RX mailbox is held under
// consumer backpressure. CS completion schedules replies; it never executes a
// command, grants a body ACK, or qualifies a link-proof heartbeat.
module a_spi_poll_event(input clk,rst_n,spi_cs_n,output poll_finished);
(* async_reg=1,preserve=1 *) reg cs_meta,cs_sync;
reg cs_previous;
assign poll_finished=cs_sync&&!cs_previous;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin cs_meta<=1;cs_sync<=1;cs_previous<=1;end
 else begin cs_meta<=spi_cs_n;cs_sync<=cs_meta;cs_previous<=cs_sync;end
end
endmodule
