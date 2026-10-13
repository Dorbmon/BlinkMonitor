"""Hardware-independent blink detector; behavior mirrors Sources/BlinkCore."""
from dataclasses import dataclass, asdict
import math


@dataclass
class Detection:
    state: str = "noFace"
    calibrationProgress: float = 0.0
    openness: float = 0.0
    didBlink: bool = False
    trackedDuration: float = 0.0

    def json(self):
        return asdict(self)


class BlinkDetector:
    def __init__(self, sensitivity=0.58):
        self.sensitivity = min(0.8, max(0.4, sensitivity))
        self.samples = []
        self.calibration_start = None
        self.baseline = None
        self.previous = None
        self.last_valid = None
        self.closed_at = None
        self.last_blink = -math.inf
        self.armed = False

    def process(self, eyes, timestamp):
        if eyes is None or not all(math.isfinite(x) and 0 < x < 1 for x in eyes):
            self.closed_at = None
            self.armed = False
            self.previous = None
            if self.baseline is None:
                self.samples.clear()
                self.calibration_start = None
            return Detection()
        if self.last_valid is not None and timestamp - self.last_valid > 3:
            self.__init__(self.sensitivity)
        self.last_valid = timestamp
        if self.baseline is None:
            if self.calibration_start is None:
                self.calibration_start = timestamp
            self.samples.append(eyes)
            progress = min(1.0, (timestamp - self.calibration_start) / 2, len(self.samples) / 40)
            if progress >= 1:
                index = int((len(self.samples) - 1) * 0.8)
                self.baseline = tuple(sorted(x[i] for x in self.samples)[index] for i in (0, 1))
                self.samples.clear()
                self.previous = timestamp
            return Detection(state="calibrating", calibrationProgress=progress)
        delta = timestamp - self.previous if self.previous is not None else 0
        self.previous = timestamp
        continuous = 0 < delta <= 0.25
        if not continuous:
            self.closed_at = None
            self.armed = False
        left, right = (eyes[i] / self.baseline[i] for i in (0, 1))
        closed = left < self.sensitivity and right < self.sensitivity
        reopened = left > self.sensitivity + 0.16 and right > self.sensitivity + 0.16
        blink = False
        if reopened:
            if self.closed_at is not None:
                duration = timestamp - self.closed_at
                blink = 0.025 <= duration <= 0.8 and timestamp - self.last_blink >= 0.18
                if blink:
                    self.last_blink = timestamp
            self.closed_at = None
            self.armed = True
            if 0.85 < left < 1.3 and 0.85 < right < 1.3:
                self.baseline = tuple(self.baseline[i] * 0.995 + eyes[i] * 0.005 for i in (0, 1))
        elif closed and self.armed and self.closed_at is None:
            self.closed_at = timestamp
            self.armed = False
        return Detection("tracking", 1.0, min(1.2, max(0, (left + right) / 2)), blink, delta if continuous else 0)


def aspect_ratio(points):
    if len(points) < 4 or not all(math.isfinite(c) for point in points for c in point):
        return None
    width, axis = 0.0, (0.0, 0.0)
    for i, first in enumerate(points):
        for second in points[i + 1:]:
            dx, dy = second[0] - first[0], second[1] - first[1]
            length = math.hypot(dx, dy)
            if length > width:
                width, axis = length, (dx, dy)
    if width <= 0.001:
        return None
    heights = [(-axis[1] * x + axis[0] * y) / width for x, y in points]
    return (max(heights) - min(heights)) / width
