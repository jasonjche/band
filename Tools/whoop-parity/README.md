# WHOOP ↔ NOOP screenshot pairs

Captures every Native screen we copy from WHOOP, next to the WHOOP page it maps to.

## Map

`screens.json` is the list. **copy** is in scope. **skip** is commerce, Humans, coach, WHOOP Age, Behavior Insights, Customize.

## Capture

Reuse a prior WHOOP dump:

```bash
python3 Tools/whoop-parity/capture.py \
  --whoop-dir ~/iphone-agent/whoop-tour \
  --out Tools/whoop-parity/out
```

Drive WHOOP live (Appium on the physical iPhone):

```bash
python3 Tools/whoop-parity/capture.py --whoop-live --out Tools/whoop-parity/out
```

Drive NOOP on the simulator (T3 `agent-device`):

```bash
python3 Tools/whoop-parity/capture.py \
  --whoop-dir ~/iphone-agent/whoop-tour \
  --agent-device /path/to/agent-device \
  --out Tools/whoop-parity/out
```

Open `Tools/whoop-parity/out/index.html`.
