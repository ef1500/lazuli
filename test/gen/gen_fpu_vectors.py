"""Regenerates test/fpu_vectors.vhdl: bit-exact IEEE-754 reference vectors
for generic_fpu.vhdl (ADD, MUL, MAX, I2F, F2I, F16_TO_F32, F32_TO_F16),
computed independently in Python/struct rather than by re-deriving the
VHDL's own bit-level math. Run from anywhere; it writes its output next
to this script's parent (test/fpu_vectors.vhdl).

    python test/gen/gen_fpu_vectors.py
"""
import struct, random, sys, math, os

def to_u32_fp32(mag_bits_or_bits):
    return mag_bits_or_bits & 0xFFFFFFFF

def f32_bits_of(x):
    """Round a (possibly double-precision) python float to hardware fp32
    bits: normal round-to-nearest-even, denormals flushed to signed zero,
    overflow saturated to the largest-magnitude normal (never +-inf)."""
    if x != x:
        raise ValueError("NaN not expected in test vectors")
    sign = 1 if math.copysign(1.0, x) < 0 else 0
    mag = abs(x)
    if mag == 0.0:
        return sign << 31
    try:
        bits = struct.unpack('<I', struct.pack('<f', mag))[0]
    except OverflowError:
        bits = 0x7F800000
    exp = (bits >> 23) & 0xFF
    if exp == 255:
        return (sign << 31) | 0x7F7FFFFF
    if exp == 0:
        return sign << 31
    return (sign << 31) | bits

def bits_to_f32(u):
    return struct.unpack('<f', struct.pack('<I', u & 0xFFFFFFFF))[0]

def u32(i):
    return i & 0xFFFFFFFF

random.seed(1234)
cases = []

def add_case(op, a, b, expect, name):
    cases.append((op, a, b, expect, name))

# ---- ADD ----
pairs = [(1.0,2.0),(1.5,2.5),(0.0,0.0),(-0.0,0.0),(1.0,-1.0),(100.0,-100.0),
         (1.0,1e-8),(1e30,1e30),(-1e30,-1e30),(3.14159,2.71828),(0.1,0.2),
         (1.0,0.0),(0.0,-5.0),(2.5,2.5),(1.9999999,0.0000001),(-3.5,1.25),
         (16777216.0, 1.0), (33554434.0, 1.0), (3.0e38, 3.0e38), (1e-40, 1e-40)]
for _ in range(200):
    pairs.append((random.uniform(-1e6,1e6), random.uniform(-1e6,1e6)))
for _ in range(50):
    pairs.append((random.uniform(-1e-30,1e-30), random.uniform(-1e-30,1e-30)))
for a,b in pairs:
    abits = f32_bits_of(a)
    bbits = f32_bits_of(b)
    real = bits_to_f32(abits) + bits_to_f32(bbits)
    add_case('ADD', abits, bbits, f32_bits_of(real), f"add {a} {b}")

# ---- MUL ----
mpairs = [(1.0,2.0),(1.5,2.5),(0.0,5.0),(-1.0,-1.0),(3.14159,2.71828),
          (1e20,1e20),(1e-20,1e-20),(-2.0,3.0),(0.1,0.1),(1e25,1e25),(1e-25,1e-25)]
for _ in range(200):
    mpairs.append((random.uniform(-1e6,1e6), random.uniform(-1e6,1e6)))
for a,b in mpairs:
    abits = f32_bits_of(a)
    bbits = f32_bits_of(b)
    real = bits_to_f32(abits) * bits_to_f32(bbits)
    add_case('MUL', abits, bbits, f32_bits_of(real), f"mul {a} {b}")

# ---- MAX ----
maxp = [(1.0,2.0),(-1.0,-2.0),(0.0,-0.0),(-5.0,5.0),(3.0,3.0),(-1.0,1.0)]
for _ in range(100):
    maxp.append((random.uniform(-1e6,1e6), random.uniform(-1e6,1e6)))
for a,b in maxp:
    abits = f32_bits_of(a); bbits = f32_bits_of(b)
    ra, rb = bits_to_f32(abits), bits_to_f32(bbits)
    expect = abits if ra >= rb else bbits
    add_case('MAX', abits, bbits, expect, f"max {a} {b}")

# ---- I2F ----
ivals = [0,1,-1,2,-2,3,-3,100,-100,2**31-1,-(2**31),12345678,-12345678,16777216,16777217,-16777217]
for _ in range(150):
    ivals.append(random.randint(-2**31, 2**31-1))
for iv in ivals:
    add_case('I2F', u32(iv), 0, f32_bits_of(float(iv)), f"i2f {iv}")

# ---- F2I (round-nearest-even, saturate) ----
fvals = [0.0,1.0,-1.0,1.5,2.5,-1.5,-2.5,3.5,-3.5,0.49,0.5,0.51,-0.5,1e10,-1e10,
         2147483647.0, -2147483648.0, 3000000000.0, -3000000000.0, 1e-10, 2147483520.0]
for _ in range(150):
    fvals.append(random.uniform(-1e5,1e5))
for fv in fvals:
    bits = f32_bits_of(fv)
    real = bits_to_f32(bits)
    r = round(real)  # python 'round' on .5 ties goes to even, matches RNE
    if r > 2**31-1:
        r = 2**31-1
    if r < -2**31:
        r = -(2**31)
    add_case('F2I', bits, 0, u32(r), f"f2i {fv}")

# ---- F16_TO_F32 ----
import numpy as np
h_vals = [0.0,1.0,-1.0,1.5,65504.0,-65504.0,0.00006103515625,3.14159]
for _ in range(80):
    h_vals.append(random.uniform(-1000,1000))
for hv in h_vals:
    h = np.float16(hv)
    hbits = int(h.view(np.uint16))
    hexp = (hbits >> 10) & 0x1F
    if hexp == 0:
        fbits = (hbits & 0x8000) << 16
    else:
        f = np.float32(h)
        fbits = int(f.view(np.uint32))
    add_case('F16_TO_F32', hbits, 0, u32(fbits), f"f16_to_f32 {hv}")

# ---- F32_TO_F16 (well in range, no mantissa-carry-into-exponent edge cases) ----
f32h_vals = [0.0,1.0,-1.0,1.5,100.25,-100.25,3.14159,65000.0,-65000.0]
for _ in range(80):
    f32h_vals.append(random.uniform(-1000,1000))
for fv in f32h_vals:
    fbits = f32_bits_of(fv)
    real = bits_to_f32(fbits)
    h = np.float32(real).astype(np.float16)
    hbits = int(h.view(np.uint16))
    add_case('F32_TO_F16', fbits, 0, u32(hbits), f"f32_to_f16 {fv}")

print(len(cases), "cases", file=sys.stderr)

out_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'fpu_vectors.vhdl')
with open(out_path, 'w') as f:
    f.write("-- AUTO-GENERATED by test/gen/gen_fpu_vectors.py -- do not hand-edit.\n")
    f.write("-- Regenerate with: python test/gen/gen_fpu_vectors.py\n")
    f.write("library IEEE;\nuse IEEE.STD_LOGIC_1164.ALL;\nuse work.project_types.all;\n\n")
    f.write("package fpu_vectors is\n")
    f.write("  type case_t is record\n")
    f.write("    op : alu_op_t;\n")
    f.write("    cvt : cvt_op_t;\n")
    f.write("    a : std_logic_vector(31 downto 0);\n")
    f.write("    b : std_logic_vector(31 downto 0);\n")
    f.write("    expect : std_logic_vector(31 downto 0);\n")
    f.write("  end record;\n")
    f.write("  type case_arr_t is array (natural range <>) of case_t;\n")
    f.write(f"  constant VECTORS : case_arr_t(0 to {len(cases)-1}) := (\n")
    op_map = {'ADD':'ALU_ADD','MUL':'ALU_MUL','MAX':'ALU_MAX'}
    for i,(op,a,b,expect,name) in enumerate(cases):
        if op in op_map:
            alu_op = op_map[op]; cvt_op = 'CVT_I2F'
        elif op == 'I2F':
            alu_op = 'ALU_CVT'; cvt_op='CVT_I2F'
        elif op == 'F2I':
            alu_op = 'ALU_CVT'; cvt_op='CVT_F2I'
        elif op == 'F16_TO_F32':
            alu_op = 'ALU_CVT'; cvt_op='CVT_F16_TO_F32'
        elif op == 'F32_TO_F16':
            alu_op = 'ALU_CVT'; cvt_op='CVT_F32_TO_F16'
        comma = ',' if i < len(cases)-1 else ''
        f.write(f'    ({alu_op}, {cvt_op}, x"{a & 0xFFFFFFFF:08X}", x"{b & 0xFFFFFFFF:08X}", x"{expect & 0xFFFFFFFF:08X}"){comma} -- {name}\n')
    f.write("  );\nend package fpu_vectors;\n")

print("wrote", out_path, "with", len(cases), "cases")
