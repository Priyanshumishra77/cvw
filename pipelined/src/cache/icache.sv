///////////////////////////////////////////
// icache.sv
//
// Written: jaallen@g.hmc.edu 2021-03-02
// Modified: 
//
// Purpose: Cache instructions for the ifu so it can access memory less often, saving cycles
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, 
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software 
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES 
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT 
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

`include "wally-config.vh"

module icache #(parameter integer LINELEN, 
				parameter integer NUMLINES,
				parameter integer NUMWAYS)
  (
   // Basic pipeline stuff
   input logic 				  clk, reset,
   input logic 				  CPUBusy,

   // mmu
   input logic [1:0] 		  IfuRWF,

   // cpu side 
   input logic 				  InvalidateICacheM,
   input logic [11:0] 		  PCNextF,
   input logic [`PA_BITS-1:0] PCPF,
   input logic [`XLEN-1:0] 	  PCF,

   // bus fsm interface
   input logic 				  IgnoreRequest,
   input logic [LINELEN-1:0]  ICacheMemWriteData,
   output logic 			  ICacheFetchLine,

   (* mark_debug = "true" *) input logic ICacheBusAck,
   (* mark_debug = "true" *) output logic [`PA_BITS-1:0] ICacheBusAdr,
   // High if the icache is requesting a stall
   output logic 			  ICacheStallF,
  
   // The raw (not decompressed) instruction that was requested
   // If this instruction is compressed, upper 16 bits may be the next 16 bits or may be zeros
   (* mark_debug = "true" *) output logic [31:0] FinalInstrRawF
   );

  // Configuration parameters
  localparam integer 		  LINEBYTELEN = LINELEN/8;

  localparam integer 		  OFFSETLEN = $clog2(LINEBYTELEN);
  localparam integer 		  INDEXLEN = $clog2(NUMLINES);
  localparam integer 		  TAGLEN = `PA_BITS - OFFSETLEN - INDEXLEN;

  // *** not used?
  localparam WORDSPERLINE = LINELEN/`XLEN;
  localparam LOGWPL = $clog2(WORDSPERLINE);


  

  // Input signals to cache memory
  logic 					  ICacheMemWriteEnable;
  // Output signals from cache memory
  logic [LINELEN-1:0] 		  ReadLineF;
  logic       				  SelAdr;
  logic [INDEXLEN-1:0] 		  RAdr;
  logic [NUMWAYS-1:0] 		  VictimWay;
  logic 					  LRUWriteEn;
  logic [NUMWAYS-1:0] 		  WayHit;
  logic 					  hit;
  
  
  logic [LINELEN-1:0] 		  ReadDataLineWayMasked [NUMWAYS-1:0];

  logic [31:0] 				  ReadLineSetsF [LINELEN/16-1:0];
  
  logic [NUMWAYS-1:0] 		  SRAMWayWriteEnable;


  mux2 #(INDEXLEN)
  AdrSelMux(.d0(PCNextF[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
			.d1(PCF[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
			.s(SelAdr),
			.y(RAdr));


  cacheway #(.NUMLINES(NUMLINES), .LINELEN(LINELEN), .TAGLEN(TAGLEN), 
			 .OFFSETLEN(OFFSETLEN), .INDEXLEN(INDEXLEN), .DIRTY_BITS(0))
  MemWay[NUMWAYS-1:0](.clk, .reset, .RAdr,
					  .PAdr(PCPF),
					  .WriteEnable(SRAMWayWriteEnable),
					  .VDWriteEnable(1'b0),
					  .WriteWordEnable({{(LINELEN/`XLEN){1'b1}}}),
					  .TagWriteEnable(SRAMWayWriteEnable),
					  .WriteData(ICacheMemWriteData),
					  .SetValid(ICacheMemWriteEnable),
					  .ClearValid(1'b0), .SetDirty(1'b0), .ClearDirty(1'b0), .SelEvict(1'b0),
					  .VictimWay,
					  .FlushWay(1'b0), .SelFlush(1'b0),
					  .ReadDataLineWayMasked, .WayHit,
					  .VictimDirtyWay(), .VictimTagWay(),
					  .InvalidateAll(InvalidateICacheM));
  
  if(NUMWAYS > 1) begin:vict
    cachereplacementpolicy #(NUMWAYS, INDEXLEN, OFFSETLEN, NUMLINES)
    cachereplacementpolicy(.clk, .reset,
              .WayHit,
              .VictimWay,
              .LsuPAdrM(PCPF[INDEXLEN+OFFSETLEN-1:OFFSETLEN]),
              .RAdr,
              .LRUWriteEn);
  end else begin:vict
    assign VictimWay = 1'b1; // one hot.
  end

  assign hit = | WayHit;

  // ReadDataLineWayMasked is a 2d array of cache line len by number of ways.
  // Need to OR together each way in a bitwise manner.
  // Final part of the AO Mux.  First is the AND in the cacheway.
  or_rows #(NUMWAYS, LINELEN) ReadDataAOMux(.a(ReadDataLineWayMasked), .y(ReadLineF));

  genvar index;
	for(index = 0; index < LINELEN / 16 - 1; index++) 
	  assign ReadLineSetsF[index] = ReadLineF[((index+1)*16)+16-1 : (index*16)];
	assign ReadLineSetsF[LINELEN/16-1] = {16'b0, ReadLineF[LINELEN-1:LINELEN-16]};

  assign FinalInstrRawF = ReadLineSetsF[PCPF[$clog2(LINELEN / 32) + 1 : 1]];

  assign ICacheBusAdr = {PCPF[`PA_BITS-1:OFFSETLEN], {{OFFSETLEN}{1'b0}}};
  
  
  // truncate the offset from PCPF for memory address generation

  assign SRAMWayWriteEnable = ICacheMemWriteEnable ? VictimWay : '0;


  icachefsm  icachefsm(.clk,
					   .reset,
					   .CPUBusy,
					   .ICacheMemWriteEnable,
					   .ICacheStallF,
					   .IgnoreRequest,
					   .ICacheBusAck,
					   .ICacheFetchLine,
					   .IfuRWF,
					   .hit,
					   .SelAdr,
					   .LRUWriteEn);

endmodule

