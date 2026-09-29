library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for qk_lanes.vhdl. DIM=4, NUM_Q=2 -- small
-- enough to hand-compute every dot product, including int8 extremes
-- (-128/127) to prove the 16-bit-per-element-product width is enough.
entity tb_qk_lanes is
end entity;

architecture sim of tb_qk_lanes is
  constant DIM     : positive := 4;
  constant NUM_Q   : positive := 2;
  constant SCORE_W : positive := 18; -- 16 + clog2(4)

  signal clk  : std_logic := '0';
  signal done : boolean   := false;

  signal ce    : std_logic := '0';
  signal k_vec : std_logic_vector(DIM * 8 - 1 downto 0)         := (others => '0');
  signal q_vec : std_logic_vector(NUM_Q * DIM * 8 - 1 downto 0) := (others => '0');
  signal score : std_logic_vector(NUM_Q * SCORE_W - 1 downto 0);

  function byte(v : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(v, 8));
  end function;
begin

  dut : entity work.qk_lanes
    generic map (DIM => DIM, NUM_Q => NUM_Q)
    port map (clk => clk, ce => ce, k_vec => k_vec, q_vec => q_vec, score => score);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        fails := fails + 1;
        report "FAIL: " & msg severity error;
      end if;
    end procedure;

    procedure check_score(q : natural; expect : integer; msg : string) is
      variable got : signed(SCORE_W - 1 downto 0);
    begin
      got := signed(score((q + 1) * SCORE_W - 1 downto q * SCORE_W));
      check(to_integer(got) = expect, msg & " (got " & integer'image(to_integer(got)) &
            ", expected " & integer'image(expect) & ")");
    end procedure;
  begin
    -- k = [1,-2,3,4]; q0 = [2,2,2,2] -> products [2,-4,6,8] -> 12
    --                 q1 = [1,1,1,1] -> products [1,-2,3,4] -> 6
    k_vec <= byte(4) & byte(3) & byte(-2) & byte(1);
    q_vec <= (byte(1) & byte(1) & byte(1) & byte(1)) &  -- query 1 (upper)
             (byte(2) & byte(2) & byte(2) & byte(2));   -- query 0 (lower)
    ce <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    check_score(0, 12, "case 1, query 0");
    check_score(1, 6,  "case 1, query 1");

    -- int8 extremes: k = [-128,127,-128,127]
    --   q0 = [127,127,127,127]  -> -16256+16129-16256+16129 = -254
    --   q1 = [-128,-128,-128,-128] -> 16384-16256+16384-16256 = 256
    k_vec <= byte(127) & byte(-128) & byte(127) & byte(-128);
    q_vec <= (byte(-128) & byte(-128) & byte(-128) & byte(-128)) &
             (byte(127) & byte(127) & byte(127) & byte(127));
    wait until rising_edge(clk); wait for 1 ns;
    check_score(0, -254, "case 2, query 0 (int8 extremes)");
    check_score(1, 256,  "case 2, query 1 (int8 extremes)");

    -- ce dropped: score must hold its last value, not update
    ce <= '0';
    k_vec <= byte(0) & byte(0) & byte(0) & byte(0);
    wait until rising_edge(clk); wait for 1 ns;
    check_score(0, -254, "case 3, ce=0 holds previous value (query 0)");
    check_score(1, 256,  "case 3, ce=0 holds previous value (query 1)");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
