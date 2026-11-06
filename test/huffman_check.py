#!/usr/bin/env python3
"""Check all three DEFLATE alphabets and decode mixed-run streams natively."""
import gzip
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MERE = os.environ.get('MERE', 'mere')


def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, timeout=120, **kw)


def main():
    with tempfile.TemporaryDirectory(prefix='mgz-huffman-') as directory:
        tmp = Path(directory)
        binaries = {}
        for name, source in [('lengths', 'test/huffman_driver.mere'), ('gzip', 'mgzip.mere')]:
            c = tmp / (name + '.c')
            c.write_bytes(run([MERE, '-c', str(ROOT / source)]).stdout)
            binary = tmp / name
            run([os.environ.get('CC', 'cc'), '-O2', str(c), '-o', str(binary)])
            binaries[name] = str(binary)
        rng = random.Random(1141)
        count = 0
        for n, bits in [(19, 7), (30, 15), (286, 15)]:
            fibonacci = [1, 1]
            for _ in range(min(n, 30) - 2):
                fibonacci.append(sum(fibonacci[-2:]))
            cases = [[1] + [0] * (n - 1), [1] * n,
                     fibonacci + [0] * (n - len(fibonacci))]
            for _ in range(30):
                cases.append([rng.choice([0, 1, 2, 3, 1 << rng.randrange(24)]) for _ in range(n)])
            for index, frequencies in enumerate(cases):
                path = tmp / 'freq.bin'
                path.write_bytes(struct.pack('<' + 'I' * n, *frequencies))
                commands = [[binaries['lengths'], str(path), str(bits)]]
                if index < 3:
                    commands.append([MERE, str(ROOT / 'test/huffman_driver.mere'), str(path), str(bits)])
                for command in commands:
                    lengths = list(map(int, run(command).stdout.split()))
                    assert len(lengths) == n
                    assert all((f == 0 and b == 0) or (f > 0 and 1 <= b <= bits)
                               for f, b in zip(frequencies, lengths)), (n, index)
                    used = sum(1 << (bits - b) for b in lengths if b)
                    active = sum(f > 0 for f in frequencies)
                    assert used == (1 << bits if active > 1 else 1 << (bits - 1)), (n, index, used)
                    count += 1
        print(f'{count} prefix-code checks: symbol coverage, limits and exact code space')
        for seed in [1141, *range(20)]:
            rng = random.Random(seed)
            size = rng.choice([300, 1000, 4000, 10000, 40000, 120000])
            rng.choice([8, 16, 32, 64, 128, 256])
            data = bytearray()
            while len(data) < size:
                data.extend(bytes(rng.randrange(256) for _ in range(rng.randrange(1, 40))))
                data.extend(b'\0' * rng.randrange(1, 500))
            data = bytes(data[:size])
            path = tmp / f'mixed-{seed}'
            path.write_bytes(data)
            run([binaries['gzip'], str(path)])
            assert gzip.decompress(Path(str(path) + '.mgz').read_bytes()) == data, seed
        print('21 mixed-run streams: native gzip decoding matches input')


if __name__ == '__main__':
    main()
