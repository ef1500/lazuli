library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_generic_pulse_cdc is
end entity;

architecture sim of tb_generic_pulse_cdc is
  signal src_clk, dst_clk : std_logic := '0';
  signal src_rst, dst_rst : std_logic := '1';
  signal pulse_in, pulse_out : std_logic := '0';
  signal done : boolean := false;
  signal dst_pulse_count : integer := 0;
begin
  dut: entity work.generic_pulse_cdc generic map (STAGES=>2)
    port map (src_clk=>src_clk, src_rst=>src_rst, pulse_in=>pulse_in,
              dst_clk=>dst_clk, dst_rst=>dst_rst, pulse_out=>pulse_out);

  -- deliberately unrelated (asynchronous) clock periods
  src_clk <= not src_clk after 3500 ps when not done else '0'; -- ~7ns period
  dst_clk <= not dst_clk after 5300 ps when not done else '0'; -- ~10.6ns period

  count_proc: process(dst_clk)
  begin
    if rising_edge(dst_clk) and pulse_out = '1' then
      dst_pulse_count <= dst_pulse_count + 1;
    end if;
  end process;

  process
  begin
    wait for 20 ns;
    src_rst <= '0'; dst_rst <= '0';
    wait until rising_edge(src_clk);
    wait until rising_edge(src_clk);

    -- fire 5 pulses, each separated by several src_clk cycles (plenty
    -- of time for the destination side to resolve each one before the next)
    for i in 1 to 5 loop
      pulse_in <= '1';
      wait until rising_edge(src_clk);
      pulse_in <= '0';
      for j in 1 to 6 loop
        wait until rising_edge(src_clk);
      end loop;
    end loop;

    wait for 100 ns; -- let everything drain
    if dst_pulse_count /= 5 then
      report "FAIL: expected exactly 5 destination pulses for 5 source pulses, got " &
             integer'image(dst_pulse_count) severity error;
    else
      report "ALL PASS";
    end if;
    done <= true;
    wait;
  end process;
end architecture;
