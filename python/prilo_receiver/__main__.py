"""Start Prilo Receiver in an interactive terminal."""

import argparse
import sys

from . import Receiver


def main(argv=None):
    parser = argparse.ArgumentParser(description="Run the Prilo Windows receiver.")
    parser.add_argument("--manual", action="store_true", help="show manual setup details including the private access code")
    args = parser.parse_args(argv)
    try:
        with Receiver() as receiver:
            ver = f" v{receiver.version}" if receiver.version else ""
            print(f"Prilo Receiver{ver}", flush=True)
            print("Update in cmd: python -m pip install --upgrade --no-cache-dir --index-url https://pypi.org/simple prilo-receiver", flush=True)
            if args.manual:
                print(receiver.connection_details(), flush=True)
                print("Enter refreshes the details; Ctrl+C stops.", flush=True)
                while True:
                    input()
                    print(receiver.connection_details(), flush=True)
            print(f"Prilo pairing code: {receiver.pairing_code}", flush=True)
            print("Choose «Найти ПК в сети» in Prilo on Mac. Enter renews the code; Ctrl+C stops.", flush=True)
            while True:
                input()
                print(f"Prilo pairing code: {receiver.new_pairing_code()}", flush=True)
    except (KeyboardInterrupt, EOFError):
        return 0
    except (OSError, RuntimeError) as error:
        print(f"Prilo Receiver: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
