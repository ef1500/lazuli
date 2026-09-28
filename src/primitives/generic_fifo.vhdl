library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- This file implemets a generic fifo.
--
-- Write Operation: To write to the FIFO, place data on the 'wdata'
-- port and pull the 'wen' port to '1'.  Data will be clocked into the
-- FIFO of the rising edge of every clock when the 'wen' port is '1'.
-- If the FIFO is full, then the data from the previous write will be
-- overwritten.  When 'enable_fifo' is set to '0' the FIFO acts as a
-- single register: all writes are to register 0.
--
-- Read Operation: Latch the data from the 'rdata' port and pull the
-- 'ren' port to '1'.  The next item in the FIFO will appear on every
-- clock cycle where the 'ren' port is '1'.  If the FIFO is empty, the
-- 'rdata' port will not change.
--
-- The 'empty' port becomes '1' when there are zero items in the FIFO,
-- and is '0' when there are one or more items in the FIFO.
--
-- The 'full' port becomes '1' when the FIFO is completely full
-- and is '0' when the FIFO has room for more items.
--
-- The 'threshold' port allows the user to set a threshold on the
-- number of items in the FIFO. the 'below_threshold' port outputs '1'
-- when the number of items in the FIFO is below the specified
-- threshold.

entity generic_FIFO is
  generic(
    bits : integer := 4;
    depth: integer := 4
    );
  port(
    clk,rst : std_logic;
    wdata : in  std_logic_vector(bits-1 downto 0);
    wen   : in  std_logic;
    ren   : in std_logic;
    enable_fifo : std_logic := '1'; 
    threshold : in std_logic_vector(clog2(depth)-1 downto 0) := (others=>'0');
    rdata : out std_logic_vector(bits-1 downto 0);
    empty, full, below_threshold : out std_logic
    );
end entity;

architecture behavioral of generic_FIFO is
  constant maxreg : std_logic_vector :=
    std_logic_vector(to_unsigned(depth-1,clog2(depth)));
  type regs_t is array (depth-1 downto 0) of std_logic_vector(bits-1 downto 0);
  signal reg, reg_in : regs_t;
  signal count, next_count, next_count_i, cp1, cm1 :
    std_logic_vector(clog2(depth) downto 0);
  signal write_target : std_logic_vector(clog2(depth)-1 downto 0);
  signal wsel : std_logic_vector(depth-1 downto 0);
  signal full_i, empty_i : std_logic;
  signal count_up, count_down, special : boolean;
begin
  full_i <= '1' when unsigned(count) = to_unsigned(depth,clog2(depth)+1) else
            '0';
  full <= full_i;
  empty_i <= '1' when unsigned(count) = to_unsigned(0,clog2(depth)+1) else
             '0';
  empty <= empty_i;
  below_threshold <= '1' when unsigned(count) < unsigned(threshold) else '0';

  count_up <= to_boolean(wen and not ren and not full_i);
  count_down <= to_boolean(not wen and ren and not empty_i);
  cp1 <= std_logic_vector(unsigned(count) + 1);
  cm1 <= std_logic_vector(unsigned(count) - 1);
  
  -- The counter tracks how many things are in the FIFO
  count <= next_count when rising_edge(clk);
  next_count <= (others => '0') when rst = '1' or enable_fifo = '0' else
                next_count_i;
  with to_vector(ren) & wen & full_i & empty_i select
    next_count_i <=
      cm1 when "1000"|"1010",
      cp1 when "0100"|"0101",
      count when others;

  -- Special causes reg(0) to be loaded when a simultaneous r/w occurs on an
  -- empty FIFO.
  special <= to_boolean(ren and wen and empty_i); 
  write_target <= (others => '0') when enable_fifo = '0' else
                  maxreg when full_i = '1' else
                  count(clog2(depth)-1 downto 0) when ren = '0' or special else
                  cm1(clog2(depth)-1 downto 0);
  
  -- Used to select a register during a write operation
  wsel <= decode(write_target,wen);

  -- Create the registers
  regs:  for I in 0 to depth-1 generate
    regI: reg(I) <= reg_in(I) when rising_edge(clk);
  end generate;

  -- The highest register remains unchanged unless explicitly written to.
  reg_in(depth-1) <= (others => '0') when rst='1' else
                     wdata when wsel(depth-1)='1' else
                     reg(depth-1);

  -- Register zero remains unchanged thew the count is less than 1 and
  -- a read occurs.
  reg_in(0) <= (others => '0') when rst='1' else
               wdata when wsel(0) = '1' else
               reg(1) when unsigned(count) > 1 and ren = '1' else 
               reg(0);

  -- These muxes select the data in for each of the registers
  muxes:  for I in 1 to depth-2 generate
    mux_I: reg_in(I) <= (others => '0') when rst='1' else
                        wdata when wsel(I) = '1' else
                        reg(I+1) when ren = '1' else
                        reg(I);
  end generate;

  -- If the fifo is empty, and a simultaneous read/write occurs, then
  -- pass wdata to rdata
  
  rdata <= wdata when to_boolean(empty_i) and to_boolean(ren) and
           to_boolean(wen) else reg(0);
  
end architecture;