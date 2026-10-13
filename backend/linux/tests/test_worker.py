import unittest
from pathlib import Path
from unittest.mock import Mock, patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from blink_backend import CameraWorker


class WorkerTests(unittest.TestCase):
    def make_worker(self, opened=True):
        worker = CameraWorker(Path('/unused/model'))
        capture = Mock()
        capture.isOpened.return_value = opened
        model = Mock()
        cv = Mock()
        cv.VideoCapture.return_value = capture
        def load():
            worker.cv2 = cv
            worker.landmarker = model
        worker.load_runtime = load
        return worker, capture, model

    @patch('blink_backend.os.access', return_value=True)
    @patch('blink_backend.os.path.exists', return_value=True)
    def test_start_and_stop_release_camera_and_model(self, *_):
        worker, capture, model = self.make_worker()
        worker.start({'runId': 'session', 'cameraId': '/dev/video0', 'sensitivity': .58})
        self.assertEqual(worker.run_id, 'session')
        worker.stop()
        capture.release.assert_called_once()
        model.close.assert_called_once()
        self.assertIsNone(worker.capture)
        self.assertIsNone(worker.run_id)

    @patch('blink_backend.os.access', return_value=True)
    @patch('blink_backend.os.path.exists', return_value=True)
    def test_failed_open_releases_both_resources(self, *_):
        worker, capture, model = self.make_worker(opened=False)
        with self.assertRaisesRegex(RuntimeError, 'Cannot open'):
            worker.start({'runId': 'session', 'cameraId': '/dev/video0'})
        capture.release.assert_called_once()
        model.close.assert_called_once()
        self.assertIsNone(worker.capture)

    @patch('blink_backend.os.access', return_value=False)
    @patch('blink_backend.os.path.exists', return_value=True)
    def test_permission_failure_never_loads_model_or_opens_camera(self, *_):
        worker = CameraWorker(Path('/unused/model'))
        worker.load_runtime = Mock()
        with self.assertRaises(PermissionError):
            worker.start({'runId': 'session', 'cameraId': '/dev/video0'})
        worker.load_runtime.assert_not_called()


if __name__ == '__main__': unittest.main()
