"""Check output timing detection across different reference/device sample rates."""
import base64
from pathlib import Path
import sys
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from measure_handoff import analyse, resample


class MeasurementTests(unittest.TestCase):
    def test_continuity_and_inserted_time_at_different_device_rate(self):
        source_rate, device_rate = 44100, 48000

        def signal(time):
            return .21 * np.sin(2 * np.pi * (93 * time + 49 * time ** 2)) + .12 * np.sin(2 * np.pi * (501 * time + 137 * time ** 2)) + .11 * np.sin(2 * np.pi * 13789 * time)

        encode = lambda array: base64.b64encode(array.astype('<f4').tobytes()).decode('ascii')
        reference = {'rate': source_rate, 'tail': 2.5, 'head': 3,
                     'a': encode(signal(np.arange(int(2.5 * source_rate)) / source_rate)),
                     'b': encode(signal(2.5 + np.arange(3 * source_rate) / source_rate))}
        for gap in [0, .1]:
            with self.subTest(gap=gap):
                time = np.arange(7 * device_rate) / device_rate - .3
                adjusted = np.where(time >= 2.74 + gap, time - gap, time)
                output = signal(adjusted)
                output[(time < 0) | ((time >= 2.74) & (time < 2.74 + gap))] = 0
                result = analyse(resample(output, device_rate), reference)
                self.assertAlmostEqual(result['insertedTimeMs'], gap * 1000, delta=.125)
                self.assertEqual(result['pass'], gap == 0)


if __name__ == '__main__':
    unittest.main()
