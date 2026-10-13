import json
from pathlib import Path
import subprocess
import sys
import unittest

BACKEND = Path(__file__).resolve().parents[1] / 'blink_backend.py'


class ProtocolTests(unittest.TestCase):
    def request(self, requests):
        process = subprocess.run([sys.executable, str(BACKEND), '--model', '/missing/model.task'],
            input='\n'.join(json.dumps(row) for row in requests) + '\n', text=True, capture_output=True, timeout=5)
        self.assertEqual(process.returncode, 0, process.stderr)
        return [json.loads(line) for line in process.stdout.splitlines()]

    def test_ping_list_stop_without_camera_dependencies(self):
        responses = self.request([{'id': 1, 'method': 'ping'}, {'id': 2, 'method': 'cameras'}, {'id': 3, 'method': 'stop'}])
        self.assertEqual(responses[0], {'id': 1, 'result': {'protocol': 1}})
        self.assertIsInstance(responses[1]['result'], list)
        self.assertEqual(responses[2], {'id': 3, 'result': None})

    def test_bad_commands_return_errors_and_worker_survives(self):
        responses = self.request([{'id': 1, 'method': 'unknown'}, {'id': 2, 'method': 'start', 'args': {'runId': 'test', 'cameraId': 'https://camera.invalid'}}, {'id': 3, 'method': 'ping'}])
        self.assertIn('Unknown method', responses[0]['error'])
        self.assertIn('local /dev/video', responses[1]['error'])
        self.assertEqual(responses[2]['result']['protocol'], 1)

    def test_invalid_sensitivity_is_rejected(self):
        response = self.request([{'id': 1, 'method': 'recalibrate', 'args': {'sensitivity': 5}}])[0]
        self.assertIn('between', response['error'])


if __name__ == '__main__': unittest.main()
