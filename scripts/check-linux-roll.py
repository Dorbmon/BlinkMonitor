#!/usr/bin/env python3
"""Optional real MediaPipe pipeline check; reads a local portrait, never a camera."""
import argparse
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend' / 'linux'))
import blink_backend


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('portrait', type=Path)
    parser.add_argument('--model', required=True, type=Path)
    args = parser.parse_args()
    worker = blink_backend.CameraWorker(args.model)
    events = []
    blink_backend.emit = events.append

    class FixtureCapture:
        image = None

        def read(self):
            return True, self.image.copy()

        def release(self):
            pass

    try:
        worker.load_runtime()
        original = worker.cv2.imread(str(args.portrait))
        if original is None:
            raise ValueError('Could not read portrait')
        capture = FixtureCapture()
        capture.image = original
        worker.capture = capture
        worker.run_id = 'fixture'
        worker.last_wall_frame = time.time()
        deadline = time.monotonic() + 15
        while worker.detector.baseline is None and time.monotonic() < deadline:
            worker.frame()
        if worker.detector.baseline is None:
            raise AssertionError('Could not calibrate the portrait')
        pivot = worker.face_center
        height, width = original.shape[:2]
        for angle in (-45, -30, -15, 0, 15, 30, 45):
            rotation = worker.cv2.getRotationMatrix2D(pivot, angle, 1.0)
            capture.image = worker.cv2.warpAffine(original, rotation, (width, height))
            for _ in range(12):
                worker.frame()
            event = events[-1]
            print(f'{angle}°: state={event["state"]}, openness={event["openness"]:.3f}')
            assert event['state'] == 'tracking', event
            assert .75 <= event['openness'] <= 1.2, event
    finally:
        worker.stop()


if __name__ == '__main__':
    main()
