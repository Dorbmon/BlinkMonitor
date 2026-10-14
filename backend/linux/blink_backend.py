#!/usr/bin/env python3
"""Linux V4L2 + MediaPipe worker. JSON-lines over stdin/stdout; logs on stderr.

Input:  {"id": 1, "method": "start", "args": {"runId": "…", ...}}
Reply:  {"id": 1, "result": null} OR {"id": 1, "error": "…"}
Event:  {"type": "frame", "runId": "…", "timestamp": <epoch seconds>, ...}
"""
import argparse
import glob
import json
import math
import os
from pathlib import Path
import queue
import re
import signal
import sys
import threading
import time

from detector import BlinkDetector, aspect_ratio


def emit(message):
    print(json.dumps(message, allow_nan=False), flush=True)


def cameras():
    result = []
    for path in sorted(glob.glob('/dev/video*'), key=lambda x: int(re.search(r'\d+$', x).group())):
        name_path = Path('/sys/class/video4linux') / Path(path).name / 'name'
        try:
            name = name_path.read_text().strip()
        except OSError:
            name = Path(path).name
        result.append({'id': path, 'name': f'{name} ({path})'})
    return result


class CameraWorker:
    def __init__(self, model):
        self.model = model
        self.capture = None
        self.landmarker = None
        self.detector = BlinkDetector()
        self.run_id = None
        self.last_timestamp_ms = -1
        self.last_wall_frame = 0
        self.failures = 0
        self.roll = 0.0
        self.face_center = None

    def load_runtime(self):
        try:
            import cv2
            import mediapipe as mp
        except ImportError as error:
            raise RuntimeError('Linux camera dependencies are missing. Run scripts/setup-linux-backend.sh with Python 3.10–3.12, then restart BlinkMonitor.') from error
        if not self.model.is_file():
            raise RuntimeError(f'Face model not found at {self.model}. Run scripts/setup-linux-backend.sh.')
        self.cv2, self.mp = cv2, mp
        options = mp.tasks.vision.FaceLandmarkerOptions(
            base_options=mp.tasks.BaseOptions(model_asset_path=str(self.model)),
            running_mode=mp.tasks.vision.RunningMode.VIDEO,
            num_faces=2, min_face_detection_confidence=0.7,
            min_face_presence_confidence=0.7, min_tracking_confidence=0.7,
            output_facial_transformation_matrixes=True)
        self.landmarker = mp.tasks.vision.FaceLandmarker.create_from_options(options)

    def start(self, args):
        self.stop()
        run_id = args.get('runId')
        if not isinstance(run_id, str) or not run_id:
            raise ValueError('A nonempty runId is required')
        device = args.get('cameraId', '')
        if not isinstance(device, str) or (device and not re.fullmatch(r'/dev/video\d+', device)):
            raise ValueError('Camera must be a local /dev/video device')
        if not device:
            devices = cameras()
            if not devices:
                raise RuntimeError('No camera found. Connect a V4L2 webcam and refresh the camera list.')
            device = devices[0]['id']
        if not os.path.exists(device):
            raise RuntimeError(f'Camera {device} is disconnected.')
        if not os.access(device, os.R_OK | os.W_OK):
            raise PermissionError(f'Camera permission denied for {device}. Check your device permissions and video group membership.')
        sensitivity = validated_sensitivity(args)
        try:
            self.load_runtime()
            self.capture = self.cv2.VideoCapture(device, self.cv2.CAP_V4L2)
            if not self.capture.isOpened():
                raise RuntimeError('Cannot open the camera. Close other camera apps or choose another video device.')
            self.capture.set(self.cv2.CAP_PROP_FRAME_WIDTH, 1280)
            self.capture.set(self.cv2.CAP_PROP_FRAME_HEIGHT, 720)
            # Drivers negotiate the closest supported rate; prefer 60 for fast blinks.
            self.capture.set(self.cv2.CAP_PROP_FPS, 60)
            self.capture.set(self.cv2.CAP_PROP_BUFFERSIZE, 1)
            self.detector = BlinkDetector(sensitivity)
            self.run_id = run_id
            self.last_timestamp_ms = -1
            self.last_wall_frame = time.time()
            self.failures = 0
            self.roll = 0.0
            self.face_center = None
        except Exception:
            self.stop()
            raise

    def stop(self):
        if self.capture is not None:
            self.capture.release()
        if self.landmarker is not None:
            self.landmarker.close()
        self.capture = self.landmarker = None
        self.run_id = None

    def frame(self):
        ok, frame = self.capture.read()
        if not ok:
            self.failures += 1
            if self.failures >= 30:
                raise RuntimeError('The camera stopped delivering frames. Reconnect it and try again.')
            time.sleep(0.03)
            return
        self.failures = 0
        timestamp = time.monotonic()
        wall_timestamp = time.time()
        # CLOCK_MONOTONIC on Linux excludes suspended time. Wall-clock gaps also
        # invalidate a pending blink when the machine wakes from suspend.
        wall_gap = wall_timestamp - self.last_wall_frame
        self.last_wall_frame = wall_timestamp
        if wall_gap > 3 or wall_gap < 0:
            self.detector = BlinkDetector(self.detector.sensitivity)
        elif wall_gap > .25:
            self.detector.process(None, timestamp)
        # Monotonic timestamps also prevent false blinks across suspend/resume gaps.
        timestamp_ms = max(self.last_timestamp_ms + 1, int(timestamp * 1000))
        self.last_timestamp_ms = timestamp_ms
        height, image_width = frame.shape[:2]
        pivot = self.face_center or (image_width / 2, height / 2)
        transform = self.cv2.getRotationMatrix2D(pivot, math.degrees(self.roll), 1.0)
        frame = self.cv2.warpAffine(frame, transform, (image_width, height))
        image = self.mp.Image(image_format=self.mp.ImageFormat.SRGB,
                              data=self.cv2.cvtColor(frame, self.cv2.COLOR_BGR2RGB))
        result = self.landmarker.detect_for_video(image, timestamp_ms)
        eyes, hint = None, 'Keep your face visible and use even lighting.'
        yaw, pitch = 0.0, 0.0
        if len(result.face_landmarks) > 1:
            hint = 'More than one face detected. Keep only your face in view.'
            self.roll, self.face_center = 0.0, None
        elif len(result.face_landmarks) == 1:
            face = result.face_landmarks[0]
            width = max(p.x for p in face) - min(p.x for p in face)
            cx = (min(p.x for p in face) + max(p.x for p in face)) * image_width / 2
            cy = (min(p.y for p in face) + max(p.y for p in face)) * height / 2
            inverse = self.cv2.invertAffineTransform(transform)
            self.face_center = (float(inverse[0] @ [cx, cy, 1]), float(inverse[1] @ [cx, cy, 1]))
            dx = ((face[362].x + face[263].x) - (face[33].x + face[133].x)) * image_width
            dy = ((face[362].y + face[263].y) - (face[33].y + face[133].y)) * height
            residual = math.atan2(dy, dx)
            if residual > math.pi / 2: residual -= math.pi
            if residual < -math.pi / 2: residual += math.pi
            self.roll = min(math.pi / 2, max(-math.pi / 2, self.roll + residual * .8))
            frontal = True
            if len(result.facial_transformation_matrixes):
                rotation = result.facial_transformation_matrixes[0]
                yaw = math.atan2(-rotation[2, 0], math.hypot(rotation[0, 0], rotation[1, 0]))
                pitch = math.atan2(rotation[2, 1], rotation[2, 2])
                frontal = abs(yaw) <= .85 and abs(pitch) <= .65
            if abs(residual) > .12:
                hint = 'Adjusting to your head tilt. Hold your natural posture briefly.'
            elif not frontal:
                hint = 'Turn slightly toward the camera so both eyes remain visible.'
            elif width > .12:
                def ratio(indices):
                    return aspect_ratio([(face[i].x * image_width, face[i].y * height) for i in indices])
                left = ratio([33, 160, 158, 133, 153, 144])
                right = ratio([362, 385, 387, 263, 373, 380])
                if left is not None and right is not None:
                    eyes, hint = (left, right), ''
        else:
            self.roll, self.face_center = 0.0, None
        detection = self.detector.process(eyes, timestamp, (yaw, pitch))
        emit({'type': 'frame', 'runId': self.run_id, 'timestamp': wall_timestamp,
              'hint': hint, **detection.json()})
        # V4L2 read already paces capture. An extra sleep can discard a blink frame.


def validated_sensitivity(args):
    value = float(args.get('sensitivity', .58))
    if not math.isfinite(value) or not .4 <= value <= .8:
        raise ValueError('Sensitivity must be between 0.4 and 0.8')
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--check', action='store_true', help='Load the model without opening a camera')
    args = parser.parse_args()
    worker = CameraWorker(args.model)
    if args.check:
        try:
            worker.load_runtime()
            emit({'ready': True, 'protocol': 1})
            return 0
        except Exception as error:
            emit({'ready': False, 'error': str(error)})
            return 1
        finally:
            worker.stop()
    commands = queue.Queue()
    def read_commands():
        for line in sys.stdin:
            commands.put(line)
        commands.put(None)
    threading.Thread(target=read_commands, daemon=True).start()
    stopping = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopping.set())
    try:
        while not stopping.is_set():
            try:
                line = commands.get(timeout=0 if worker.capture is not None else .1)
            except queue.Empty:
                line = ''
            if line is None:
                break
            if line:
                request = {}
                try:
                    request = json.loads(line)
                    if not isinstance(request, dict) or not isinstance(request.get('id'), int):
                        raise ValueError('Request must contain an integer id')
                    method, params = request.get('method'), request.get('args', {})
                    if not isinstance(params, dict):
                        raise ValueError('args must be an object')
                    result = None
                    if method == 'cameras': result = cameras()
                    elif method == 'start': worker.start(params)
                    elif method == 'stop': worker.stop()
                    elif method == 'recalibrate': worker.detector = BlinkDetector(validated_sensitivity(params))
                    elif method == 'ping': result = {'protocol': 1}
                    else: raise ValueError(f'Unknown method: {method}')
                    emit({'id': request['id'], 'result': result})
                except Exception as error:
                    emit({'id': request.get('id') if isinstance(request, dict) else None, 'error': str(error)})
            if worker.capture is not None:
                try:
                    worker.frame()
                except Exception as error:
                    emit({'type': 'error', 'runId': worker.run_id, 'message': str(error)})
                    worker.stop()
    finally:
        worker.stop()
    return 0


if __name__ == '__main__':
    sys.exit(main())
