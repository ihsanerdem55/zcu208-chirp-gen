"""Parser regressions independent of numpy/matplotlib and Vivado."""
import csv
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from plot_ila import number, read_capture


class CaptureTests(unittest.TestCase):
    def capture(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.csv"
            with path.open("w", newline="") as f:
                csv.writer(f).writerows(rows)
            return read_capture(path)

    def fixture(self):
        lanes = [(1, -1), (-32768, 32767), (123, -456), (-9, 10)]
        word = sum(((i & 65535) | ((q & 65535) << 16)) << (32*n)
                   for n, (i, q) in enumerate(lanes))
        return lanes, [
            ["Sample in Buffer", "chirp/m_axis_tdata[127:0]", "chirp/trig_out",
             "chirp/m_axis_tvalid", "chirp/m_axis_tready"],
            ["Radix - UNSIGNED", "HEX", "BIN", "BIN", "BIN"],
            ["0", f"{word:032x}", "1", "1", "1"],
            ["1", f"{word:032x}", "1", "1", "1"],
        ]

    def test_signed_lane_order(self):
        lanes, rows = self.fixture()
        samples, gates = self.capture(rows)
        self.assertEqual(samples, lanes * 2)
        self.assertEqual(gates, [1] * 8)

    def test_decimal_and_probe_names(self):
        lanes, rows = self.fixture()
        rows[0][1:] = [f"ila/probe{i}" for i in range(4)]
        rows[1][1] = "UNSIGNED"
        for row in rows[2:]:
            row[1] = str(int(row[1], 16))
        self.assertEqual(self.capture(rows)[0], lanes * 2)

    def test_vivado_uppercase_bus_signal(self):
        lanes, rows = self.fixture()
        rows[0][1] = "chirp_gen_0_m_axis_TDATA[127:0]"
        self.assertEqual(self.capture(rows)[0], lanes * 2)

    def test_block_design_monitor_nets(self):
        lanes, rows = self.fixture()
        rows[0][1:] = ["chirp_bd_i/chirp_gen_0_mon_data[127:0]", "chirp_bd_i/chirp_gen_0_trig_out",
                       "chirp_bd_i/chirp_gen_0_mon_valid", "chirp_bd_i/chirp_gen_0_mon_ready"]
        rows[0].append("chirp_bd_i/iq_slice_0_Dout[15:0]")
        rows[1].append("HEX")
        for row in rows[2:]:
            row.append("0001")
        self.assertEqual(self.capture(rows)[0], lanes * 2)

    def test_unready_is_not_silently_removed(self):
        _, rows = self.fixture()
        rows[-1][-1] = "0"
        with self.assertRaisesRegex(ValueError, "not streaming"):
            self.capture(rows)

    def test_unknown_data_is_rejected(self):
        _, rows = self.fixture()
        rows[-1][1] = "xxxxxxxx"
        with self.assertRaisesRegex(ValueError, "invalid/unknown"):
            self.capture(rows)

    def test_explicit_radix(self):
        self.assertEqual(number("128'hff"), 255)
        self.assertEqual(number("1010", "BIN"), 10)
        self.assertEqual(number("-12", "SIGNED"), -12)


if __name__ == "__main__":
    unittest.main()
