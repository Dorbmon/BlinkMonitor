# Linux backend protocol (version 1)

Start `python -u blink_backend.py --model /absolute/path/face_landmarker.task`.
Each UTF-8 line on stdin is one request. Each line on stdout is one response or event. Diagnostics go to stderr. EOF, SIGINT, and SIGTERM release capture and the model.

```json
{"id":1,"method":"start","args":{"runId":"unique-session-token","cameraId":"/dev/video0","sensitivity":0.58}}
{"id":1,"result":null}
```

Commands: `ping` (returns `{"protocol":1}`), `cameras` (returns `[{"id":"/dev/video0","name":"…"}]`), `start`, `stop`, and `recalibrate` (with `sensitivity`). An empty camera ID uses the first enumerated device. Camera IDs must be local `/dev/videoN` paths. Sensitivity is 0.4–0.8.

A command failure returns `{"id":1,"error":"Actionable message"}`. Capture failures emit `{"type":"error","runId":"…","message":"…"}` and release the camera.

```json
{"type":"frame","runId":"unique-session-token","timestamp":1791900000.125,"state":"tracking","calibrationProgress":1.0,"openness":0.94,"didBlink":false,"trackedDuration":0.0333,"hint":""}
```

`timestamp` is Unix epoch seconds. Duration uses a monotonic clock and is zero after gaps >250 ms, calibration, or missing / unreliable face geometry. States are `noFace`, `calibrating`, and `tracking`. The UI must ignore events from old run IDs. Only a close/reopen transition sets `didBlink`. No image or biometric template is transmitted or saved.

The Flutter client applies a 30-second command timeout and kills a worker stuck in a device read; shutdown gives it two seconds to release cleanly before terminating it. `--check` loads the model without opening a camera and exits with a JSON diagnostic.
