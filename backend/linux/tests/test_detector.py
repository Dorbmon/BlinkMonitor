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

    def test_single_frame_fast_blink_at_60fps(self):
        for eyes in ((.1, .1), (.22, .23)):
            detector = self.calibrated()
            detector.process(eyes, 2.20)
            self.assertTrue(detector.process((.3, .3), 2.20 + 1 / 60).didBlink)
            self.assertFalse(detector.process((.3, .3), 2.25).didBlink)

    def test_shallow_wink_and_slow_squint_are_not_blinks(self):
        detector = self.calibrated()
        detector.process((.22, .3), 2.20)
        self.assertFalse(detector.process((.3, .3), 2.24).didBlink)
        for i, ratio in enumerate((.29, .27, .25, .23, .23, .25, .27, .30)):
            self.assertFalse(detector.process((ratio, ratio), 2.3 + i / 30).didBlink)

    def test_long_shallow_closure_and_face_loss_cancel_quick_dip(self):
        detector = self.calibrated()
        for i in range(13):
            self.assertFalse(detector.process((.22, .22), 2.2 + i / 30).didBlink)
        self.assertFalse(detector.process((.3, .3), 2.65).didBlink)
        detector.process((.22, .22), 2.68)
        detector.process(None, 2.70)
        self.assertFalse(detector.process((.3, .3), 2.72).didBlink)

    def test_moderate_head_turn_and_pitch(self):
        for pose in ((.7, 0), (0, .55), (.6, .45)):
            detector = self.calibrated()
            factor = math.cos(pose[1]) / math.cos(pose[0])
            for i in range(5):
                result = detector.process((.3 * factor, .3 * factor), 2.2 + i / 30, pose)
                self.assertEqual(result.state, 'tracking')
                self.assertFalse(result.didBlink)
                self.assertAlmostEqual(result.openness, 1)
            detector.process((.1 * factor, .1 * factor), 2.37, pose)
            self.assertTrue(detector.process((.3 * factor, .3 * factor), 2.40, pose).didBlink)

    def test_sudden_pose_change_cannot_create_blink(self):
        detector = self.calibrated()
        detector.process((.1, .1), 2.20, (.7, 0))
        self.assertFalse(detector.process((.3, .3), 2.24).didBlink)
        self.assertEqual(detector.process((.3, .3), 2.28, (1.1, 0)).state, 'noFace')


if __name__ == '__main__': unittest.main()
