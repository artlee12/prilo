# Fuso Receiver for Python

The Windows receiver for [Fuso on Mac](https://github.com/artlee12/prilo) as a Windows Python package. The native library uses the same Go receiver, encrypted pairing, Bonjour discovery, mouse and keyboard control, clipboard and file sync, power commands, and Happ VPN controls as the standalone release. Install it in an approved interactive Windows user session.

Install from [PyPI](https://pypi.org/project/prilo-receiver/) on Windows with Python 3.9 or newer. Pip selects the x64 or ARM64 wheel based on your Python interpreter's architecture.

```powershell
python -m pip install --upgrade prilo-receiver
if ($LASTEXITCODE -eq 0) { python -m prilo_receiver }
```

Open Fuso on Mac, choose **Find PCs on the network**, and enter the code printed in the terminal. Press Enter for a new code or Ctrl+C to stop. The saved pairing is shared with the standalone receiver for the same account. Run only one receiver at a time. The network rules for Fuso still apply to the Python host.

If automatic discovery is unavailable, stop the receiver and run `python -m prilo_receiver --manual` on Windows with version 0.9.1 or newer. Use the printed IPv4 address, access code and full certificate fingerprint in the Mac application's manual form. Connect from a network that can reach TCP port 43821 on Windows. Keep the access code private. The same details are available through `Receiver.connection_details()`.

To embed the receiver in Python:

```python
from prilo_receiver import Receiver

with Receiver() as receiver:
    print(receiver.pairing_code)
    input("Press Enter to stop. ")
```

Installing the wheel does not start a background service. The host has no tray, installer, autostart registration or self-updater. Upgrade it through the approved Python package channel.
