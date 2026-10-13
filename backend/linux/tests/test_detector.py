import math
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from detector import BlinkDetector, aspect_ratio


class DetectorTests(unittest.TestCase):
    def calibrated(self):
        detector = BlinkDetector()
        for i in range(66): detector.process((.3, .3), i / 30)
        return detector

    def test_close_reopen_counts_once(self):
        detector = self.calibrated()
        self.assertFalse(detector.process((.1, .1), 2.20).didBlink)
        self.assertTrue(detector.process((.3, .3), 2.28).didBlink)
        self.assertFalse(detector.process((.3, .3), 2.32).didBlink)

    def test_wink_is_not_a_blink(self):
        detector = self.calibrated()
        detector.process((.1, .3), 2.20)
        self.assertFalse(detector.process((.3, .3), 2.28).didBlink)

    def test_no_blink_across_face_loss_or_gap(self):
        for missing in (True, False):
            detector = self.calibrated()
            detector.process((.1, .1), 2.20)
            if missing: detector.process(None, 2.23)
            result = detector.process((.3, .3), 2.28 if missing else 2.80)
            self.assertFalse(result.didBlink)
            self.assertEqual(result.trackedDuration, 0)

    def test_long_closure_does_not_count(self):
        detector = self.calibrated()
        for i in range(31): detector.process((.1, .1), 2.2 + i / 30)
        self.assertFalse(detector.process((.3, .3), 3.24).didBlink)

    def test_absence_recalibrates(self):
        detector = self.calibrated()
        detector.process(None, 3)
        self.assertEqual(detector.process((.3, .3), 6).state, 'calibrating')

    def test_calibration_requires_time_and_samples(self):
        detector = BlinkDetector()
        for i in range(10): detector.process((.3, .3), i)
        self.assertIsNone(detector.baseline)

    def test_bad_measurement_rejected(self):
        detector = self.calibrated()
        self.assertEqual(detector.process((math.nan, .3), 2.2).state, 'noFace')

    def test_roll_and_scale_invariant_geometry(self):
        points = [(-5, 0), (-2, 1), (2, 1), (5, 0), (2, -1), (-2, -1)]
        rotated = [(3 * (x * math.cos(.4) - y * math.sin(.4)) + 100,
                    3 * (x * math.sin(.4) + y * math.cos(.4)) + 50) for x, y in points]
        self.assertAlmostEqual(aspect_ratio(points), .2)
        self.assertAlmostEqual(aspect_ratio(rotated), .2)
        self.assertIsNone(aspect_ratio([]))


if __name__ == '__main__': unittest.main()
