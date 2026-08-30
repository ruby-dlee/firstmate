"""Loopback-only transport regression, invoked by fm-crosscheck-azure.test.sh.

FM_TEST_PINNED_PI_CLI optionally points to the unpacked image-pinned Pi CLI.
No package installation, credential discovery or remote provider calls occur.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(sys.argv[1])


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


runtime = load("crosscheck_transport_runtime", ROOT / "bin/fm-crosscheck-pi-reviewer.py")
core = load("crosscheck_transport_core", ROOT / "bin/fm-crosscheck.py")
observer = runtime.EvaluationDiagnostics("challenge", 1, {"safe.py"})
observer.observe({"type": "crosscheck_provider_request", "payload": "SECRET"}, 0)
observer.observe({"type": "crosscheck_provider_response", "status": 200, "headers": {"secret": "SECRET"}}, 100)
observer.observe({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "delta": "SECRET"}}, 125)
observer.observe({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "delta": "SECRET"}}, 150)
observer.observe({"type": "message_end", "message": {"role": "assistant", "stopReason": "toolUse", "content": "SECRET"}}, 200)
observer.observe({"type": "tool_execution_start", "toolName": "report_finding", "toolCallId": "SECRET", "args": {
    "title": "SECRET", "explanation": "SECRET", "severity": "high", "merge_disposition": "must-fix",
    "citations": [{"path": "safe.py", "start_line": 1, "end_line": 2}, {"path": "/SECRET"}],
}}, 210)
observer.observe({"type": "tool_execution_end", "toolCallId": "SECRET", "result": {
    "details": {"accepted": True}, "content": [{"type": "text", "text": "SECRET"}],
}}, 220)
for i in range(200):
    observer.observe({"type": "auto_retry_start", "delayMs": 10, "errorMessage": "SECRET"}, 300 + i)
diagnostics = observer.value
assert "SECRET" not in json.dumps(diagnostics)
assert len(runtime.canonical_bytes(diagnostics)) <= observer.MAX_BYTES
assert diagnostics["truncated"] and diagnostics["omitted_events"] > 0
assert any(row.get("tool") == "report_finding" for row in diagnostics["events"])
assert diagnostics["response_wait_ms"] == 100 and diagnostics["stream_ms"] == 100
assert diagnostics["first_delta_wait_ms"] == 125 and diagnostics["max_delta_gap_ms"] == 25
assert diagnostics["tool_ms"] == 10 and diagnostics["retries"] == 200
print("Sanitized bounded diagnostics passed")

cli_raw = os.environ.get("FM_TEST_PINNED_PI_CLI")
if not cli_raw:
    print("Pinned Pi loopback transport not requested (set FM_TEST_PINNED_PI_CLI)")
    raise SystemExit(0)
cli = Path(cli_raw).resolve()
closure = json.loads((ROOT / "docs/azure-crosscheck/model-image-closure.json").read_text())
version = json.loads((cli.parent.parent / "package.json").read_text())["version"]
assert version == closure["piVersion"]["value"], "transport fixture must use the image-pinned Pi"


def exercise(scenario):
    requests = []
    server_errors = []
    release_waiters = threading.Event()

    class Provider(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                assert self.path == "/v1/chat/completions"
                raw = self.rfile.read(int(self.headers["content-length"]))
                body = json.loads(raw)
                requests.append(body)
                number = len(requests)
                assert number <= 10, "fixture produced an unexpected tool loop"
                # Complete one real tool exchange before inducing inactivity.
                # Exhaustion is also preceded by the tool in each outer repair.
                tool_present = any(row.get("role") == "tool" for row in body["messages"])
                if tool_present and (scenario == "exhaustion" or
                                     scenario == "headers-retry" and number == 2):
                    release_waiters.wait(4)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()

                def chunk(delta, finish=None):
                    event = {"id": "fixture", "object": "chat.completion.chunk", "created": 0,
                             "model": "fixture-model", "choices": [{"index": 0, "delta": delta,
                                                                        "finish_reason": finish}]}
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.flush()

                if not tool_present:
                    name, arguments = "repo_read", {"path": "safe.py", "start_line": 1, "end_line": 1}
                else:
                    if scenario == "body-retry" and number == 2:
                        chunk({"role": "assistant", "reasoning_content": "fixture"})
                        release_waiters.wait(4)
                        return
                    if scenario == "active-stream":
                        # Stream for much longer than the injected idle timeout.
                        for _ in range(16):
                            chunk({"reasoning_content": "fixture"})
                            time.sleep(0.1)
                    name, arguments = "finish_review", {
                        "verdict": "CLEAR", "summary": "Fixture only",
                        "citations": [{"path": "safe.py", "line": 1}],
                    }
                chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call-" + str(number),
                       "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]})
                chunk({}, "tool_calls")
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except BaseException as exc:
                server_errors.append((type(exc).__name__, len(raw) if "raw" in locals() else None,
                                      self.headers.get("content-length"), self.headers.get("content-encoding")))

    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="crosscheck-transport-") as temporary:
            root = Path(temporary)
            account, repository = root / "account", root / "repository"
            account.mkdir()
            repository.mkdir()
            (repository / "safe.py").write_text("PRESERVED_TOOL_RESULT = 7\n")
            (account / "models.json").write_text(json.dumps({"providers": {"fixture-provider": {
                "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": "openai-completions",
                "apiKey": "loopback-fixture-not-a-secret", "models": [{"id": "fixture-model", "name": "Fixture",
                    "reasoning": True, "input": ["text"], "contextWindow": 100000, "maxTokens": 2000,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                    "compat": {"supportsStrictMode": True}}],
            }}}))
            settings = {"httpIdleTimeoutMs": 1000, "retry": {"enabled": True, "maxRetries": 3, "baseDelayMs": 10}}
            (account / "settings.json").write_text(json.dumps(settings))
            schema, prompt, result = root / "schema.json", root / "prompt.txt", root / "result.json"
            schema.write_text(json.dumps(core.pi_review_output_schema(str(account), str(root / "home"))))
            prompt.write_text("Loopback fixture; read safe.py then finish the review.\n")
            # Nothing from the operator's environment reaches Pi or the fixture.
            environment = {key: os.environ[key] for key in ("PATH", "TMPDIR") if key in os.environ}
            environment.update({
                "HOME": str(root / "home"), "NO_PROXY": "127.0.0.1,localhost",
                "FM_CROSSCHECK_PI_COMMAND_JSON": json.dumps(["node", str(cli)]),
                "FM_CROSSCHECK_REPOSITORY": str(repository), "FM_CROSSCHECK_HEAD_SHA": "a" * 40,
                "FM_CROSSCHECK_BASE_SHA": "b" * 40, "FM_CROSSCHECK_EXECUTING_ACCOUNT_HOME": str(account),
                "FM_CROSSCHECK_EXECUTION_HOME": str(root / "home"), "FM_CROSSCHECK_REVIEW_STAGE": "challenge",
                "FM_CROSSCHECK_EVALUATION_DIAGNOSTICS": "1",
            })
            completed = subprocess.run([
                sys.executable, str(ROOT / "bin/fm-crosscheck-pi-reviewer.py"), str(account),
                "fixture-model", "xhigh", "fixture-provider", str(ROOT / "bin/fm-crosscheck-pi-verdict-extension.mjs"),
                str(prompt), str(schema), str(result),
            ], cwd=repository, env=environment, capture_output=True, text=True, timeout=40)
            assert not server_errors, server_errors
            if scenario == "exhaustion":
                assert completed.returncode == 125 and not result.exists(), completed.stderr
                assert len(requests) == 10, len(requests)  # two outer attempts, each read + four failed requests
                print("Pinned Pi: retry exhaustion never produced a verdict")
                return
            assert completed.returncode == 0, completed.stderr
            value = json.loads(result.read_text())
            diagnostics = value["review_diagnostics"][0]
            assert value["verdict"]["head_sha"] == "a" * 40
            assert [event["name"] for event in value["tool_events"]] == ["repo_read", "finish_review"]
            assert json.loads((account / "settings.json").read_text()) == settings
            if scenario == "active-stream":
                assert len(requests) == 2 and diagnostics["retries"] == 0
                assert diagnostics["stream_ms"] >= 1000, diagnostics
            else:
                assert len(requests) == 3 and diagnostics["retries"] == 1, diagnostics
                assert requests[1]["messages"] == requests[2]["messages"], "retry lost or changed earlier context"
                assert "PRESERVED_TOOL_RESULT" in json.dumps(requests[2]["messages"])
            assert diagnostics["requests"] == len(requests), diagnostics
            assert "PRESERVED_TOOL_RESULT" not in json.dumps(diagnostics)
            print(f"Pinned Pi {version}: {scenario} passed; requests={len(requests)} retries={diagnostics['retries']}")
    finally:
        release_waiters.set()
        server.shutdown()
        server.server_close()


for scenario in ("headers-retry", "body-retry", "active-stream", "exhaustion"):
    exercise(scenario)
