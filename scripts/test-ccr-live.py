#!/usr/bin/env python3
"""Opt-in real CCR/Claude lifecycle proof against a local deterministic provider."""
import argparse
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import os
from pathlib import Path
import platform
import pty
import re
import signal
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'plugins/codex-pr-review/scripts/codex-run.sh'


class Provider:
    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()
        self.release.set()
        self.requests = 0
        self.marker = None
        self.history_marker = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def send(self, value, content_type='application/json'):
                data = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(data)

            def do_GET(self):
                self.send({'data': [{'id': 'fixture-model', 'type': 'model', 'display_name': 'Fixture'}],
                           'has_more': False})

            def do_POST(self):
                size = int(self.headers.get('Content-Length', '0'))
                if size > 8 << 20:
                    self.send_error(413)
                    return
                body = json.loads(self.rfile.read(size))
                if 'count_tokens' in self.path:
                    self.send({'input_tokens': 100})
                    return
                owner.requests += 1
                matched = owner.marker is not None and owner.marker in json.dumps(body)
                if matched:
                    owner.entered.set()
                if matched and not owner.release.wait(90):
                    self.send_error(504)
                    return
                reply = 'DONE'
                if owner.history_marker is not None:
                    # The fixture only echoes a marker actually present in Claude's
                    # request history. Later prompts never carry it.
                    reply = owner.history_marker if owner.history_marker in json.dumps(body) else 'HISTORY_MISSING'
                message = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant',
                           'model': 'fixture-model', 'content': [], 'stop_reason': None,
                           'stop_sequence': None, 'usage': {'input_tokens': 100, 'output_tokens': 0}}
                if not body.get('stream'):
                    message.update(content=[{'type': 'text', 'text': reply}], stop_reason='end_turn')
                    self.send(message)
                    return
                events = [
                    ('message_start', {'type': 'message_start', 'message': message}),
                    ('content_block_start', {'type': 'content_block_start', 'index': 0,
                                             'content_block': {'type': 'text', 'text': ''}}),
                    ('content_block_delta', {'type': 'content_block_delta', 'index': 0,
                                             'delta': {'type': 'text_delta', 'text': reply}}),
                    ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
                    ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn',
                                                                       'stop_sequence': None},
                                       'usage': {'output_tokens': 1}}),
                    ('message_stop', {'type': 'message_stop'}),
                ]
                self.send(''.join(f'event: {name}\ndata: {json.dumps(data)}\n\n'
                                  for name, data in events).encode(), 'text/event-stream')

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        assert not self.thread.is_alive()

    def hold(self, marker):
        self.marker = marker
        self.entered.clear()
        self.release.clear()


def wait_for(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('readiness deadline exceeded')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', required=True, type=Path)
    parser.add_argument('--containment', choices=['process-group', 'systemd-scope'], required=True)
    args = parser.parse_args()
    out = args.artifacts.resolve()
    out.mkdir(parents=True, exist_ok=False, mode=0o700)
    env = dict(os.environ, XDG_DATA_HOME=str(out / 'data'), XDG_CONFIG_HOME=str(out / 'config'),
               CLAUDE_CONFIG_DIR=str(out / 'claude'), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
               CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL='1', CLAUDE_CODE_DISABLE_AUTO_MEMORY='1')
    provider = Provider()
    processes, jobs = [], []
    sentinel = None
    sentinel_fd = None
    sentinel_pid = None

    def run(command, *, name=None, check=True, timeout=60):
        result = subprocess.run(command, env=env, cwd=out, capture_output=True, timeout=timeout)
        if name:
            (out / (name + '.stdout')).write_bytes(result.stdout)
            (out / (name + '.stderr')).write_bytes(result.stderr)
        if check and result.returncode:
            raise AssertionError(f'{command[0]} exited {result.returncode}; evidence={name}')
        return result

    def launch(name):
        marker = uuid.uuid4().hex
        provider.hold(marker)
        (out / 'prompt').write_text(f'Reply exactly DONE. Do not use tools. Test marker: {marker}\n')
        prefix = out / name
        handle = (out / (name + '.control')).open('wb')
        try:
            process = subprocess.Popen(['bash', str(RUNNER), str(prefix), '--via', 'ccr:fixture',
                                        '--fresh', '--prompt-file', str(out / 'prompt'), '--poll-sec', '1'],
                                       env=env, cwd=out, stdout=handle, stderr=subprocess.STDOUT)
        finally:
            handle.close()
        processes.append(process)
        wait_for(lambda: Path(str(prefix) + '.detached').exists())
        receipt = json.loads(Path(str(prefix) + '.ccr-receipt.json').read_text())
        jobs.append(receipt['job_id'])
        assert provider.entered.wait(30), 'real Claude never entered the fixture provider'
        status = json.loads(run(['ccr', 'status', receipt['job_id'], '--json']).stdout)
        assert status['status'] == 'running' and status['containment'] == args.containment, status
        (out / (name + '.ready.json')).write_text(json.dumps(status, indent=2))
        return process, prefix, receipt

    try:
        versions = {tool: run([tool, 'version' if tool == 'ccr' else '--version']).stdout.decode().strip()
                    for tool in ('ccr', 'claude')}
        (out / 'versions.json').write_text(json.dumps(versions, indent=2))
        url = f'http://127.0.0.1:{provider.server.server_port}'
        run(['ccr', 'provider', 'add', 'fixture', '--type', 'anthropic-compatible',
             '--protocol', 'anthropic-compatible', '--base-url', url, '--no-api-key', '--mode', 'full'], name='provider')
        run(['ccr', 'model', 'add', 'fixture', '--provider', 'fixture', '--model', 'fixture-model',
             '--compat', 'full'], name='model')
        run(['ccr', 'model', 'update', 'fixture', '--tools', 'true', '--streaming', 'true',
             '--system-messages', 'true', '--tool-choice', 'true'], name='capabilities')
        (out / 'prompt').write_text('Reply exactly DONE. Do not use any tools.\n')
        run(['bash', str(RUNNER), '--probe', '--via', 'ccr:fixture', '--record-dir', str(out)],
            name='probe', timeout=90)
        watcher, prefix, receipt = launch('reattach')
        watcher.kill()  # Exact Popen-owned collector, never a workload/group lookup.
        watcher.wait(timeout=5)
        attach_out = (out / 'reattach.control2').open('wb')
        try:
            # --expected-job is mandatory on every attach, and the identity comes from THIS
            # launch's receipt, not from a later re-read of the prefix: a prefix outlives its
            # attempts, so re-reading would bind to whatever occupies it when the command runs.
            collector = subprocess.Popen(['bash', str(RUNNER), str(prefix), '--attach',
                                          '--expected-job', receipt['job_id'], '--poll-sec', '1'],
                                         env=env, cwd=out, stdout=attach_out, stderr=subprocess.STDOUT)
        finally:
            attach_out.close()
        processes.append(collector)
        provider.release.set()
        assert collector.wait(timeout=60) == 0, 'attached collector did not complete'
        committed = json.loads(Path(str(prefix) + '.ccr-result.json').read_text())
        assert committed['job_id'] == receipt['job_id'] and committed['successful']
        assert 'DONE' in Path(str(prefix) + '.stdout').read_text()
        # Exercise all packaged consumers against real Claude session persistence.
        provider.history_marker = uuid.uuid4().hex
        rounds = []
        phases = [('original', 'codex-pr-review'), ('review-consultation', 'codex-pr-review'),
                  ('residual-resolution', 'codex-pr-review'), ('debate', 'codex-debate'),
                  ('deep-plan', 'codex-deep-plan')]
        for phase, plugin in phases:
            runner = ROOT / 'plugins' / plugin / 'scripts/codex-run.sh'
            prefix = out / phase
            arguments = ['bash', str(runner), str(prefix), '--via', 'ccr:fixture', '--poll-sec', '1']
            if rounds:
                # Resolve before creating the next prompt, as every caller must.
                anchor = json.loads(run(['python3', str(runner.with_name('ccr-job.py')),
                                         'resolve-session', str(prefix), rounds[-1]['session_id']],
                                        name=phase + '.anchor').stdout)
                arguments += ['--resume-session', anchor['session_id'],
                              '--expected-parent-job', anchor['expected_parent_job']]
                prompt = 'Return the unpredictable marker from the original session. Do not use tools.'
            else:
                arguments += ['--fresh']
                prompt = 'Remember and return this unpredictable marker: ' + provider.history_marker
            prompt_file = out / (phase + '.prompt')
            prompt_file.write_text(prompt)
            run(arguments + ['--prompt-file', str(prompt_file)], name=phase + '.control', timeout=90)
            admitted = json.loads(Path(str(prefix) + '.ccr-attempt.json').read_text())
            current = admitted['receipt']
            jobs.append(current['job_id'])
            assert Path(str(prefix) + '.stdout').read_text().strip() == provider.history_marker, phase
            assert current['job_id'] not in [item['job_id'] for item in rounds]
            if rounds:
                assert current['session_id'] == rounds[0]['session_id']
                assert admitted['expected_parent_job'] == rounds[-1]['job_id']
            rounds.append(current)
        (out / 'continuation.json').write_text(json.dumps(rounds, indent=2))
        provider.history_marker = None
        # A separately launched interactive --chrome session is the sentinel.
        sentinel_fd, slave = pty.openpty()
        sentinel = subprocess.Popen(['ccr', 'launch', '--model', 'fixture', '--chrome',
                                     '--no-lifecycle', '--no-statusline', '--strict-mcp-config',
                                     '--mcp-config={"mcpServers":{}}'],
                                    env=env, cwd=out, stdin=slave, stdout=slave, stderr=slave,
                                    start_new_session=True)
        os.close(slave)
        os.set_blocking(sentinel_fd, False)
        captured = bytearray()

        def sentinel_ready():
            assert sentinel.poll() is None, 'interactive sentinel exited before readiness'
            with contextlib.suppress(BlockingIOError):
                captured.extend(os.read(sentinel_fd, 65536))
            return re.search(rb'session=\d+ pid=(\d+)', captured) is not None

        wait_for(sentinel_ready)
        sentinel_pid = int(re.search(rb'session=\d+ pid=(\d+)', captured)[1])
        assert sentinel_pid > 1
        def sentinel_identity():
            return subprocess.check_output(['ps', '-p', str(sentinel_pid), '-o', 'lstart=', '-o', 'comm='],
                                           env=dict(env, TZ='UTC')).decode().strip()
        before = sentinel_identity()
        assert before and sentinel.poll() is None
        (out / 'sentinel.ready.json').write_text(json.dumps({'pid': sentinel_pid, 'identity': before,
                                                            'command': 'ccr launch --chrome (interactive PTY)'}, indent=2))
        watcher, prefix, receipt = launch('cancel')
        # Cancellation names its job too: it reaches the same requirement, and an unnamed
        # cancellation would stop whichever admitted job occupies this prefix now.
        run(['bash', str(RUNNER), str(prefix), '--attach', '--expected-job', receipt['job_id'],
             '--cancel'], name='cancel-command')
        assert watcher.wait(timeout=30) == 1, 'cancelled workload was not reported failed'
        status = json.loads(run(['ccr', 'status', receipt['job_id'], '--json']).stdout)
        assert status['status'] == 'cancelled' and status['exit_code'] is not None
        assert status['cleanup']['coverage'] in ('partial', 'complete') and status['cleanup']['survivors'] == []
        assert status['containment'] == args.containment
        (out / 'cancel.final.json').write_text(json.dumps(status, indent=2))
        assert sentinel.poll() is None and sentinel_identity() == before, 'unrelated sentinel did not survive'
        (out / 'sentinel.after.json').write_text(json.dumps({'pid': sentinel_pid, 'identity': sentinel_identity(),
                                                           'survived': True}, indent=2))
        (out / 'PASS.json').write_text(json.dumps({'versions': versions, 'platform': platform.platform(),
                                                  'containment': args.containment, 'jobs': jobs,
                                                  'provider_requests': provider.requests,
                                                  'source_commit': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).decode().strip(),
                                                  'source_dirty': bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain', '--untracked-files=normal', '--', '.', ':!.live-ccr'])),
                                                  'test_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                                  'runner_sha256': hashlib.sha256(RUNNER.read_bytes()).hexdigest(),
                                                  'helper_sha256': hashlib.sha256(RUNNER.with_name('ccr-job.py').read_bytes()).hexdigest(),
                                                  'continuation_rounds': rounds, 'sentinel_survived': True}, indent=2))
        print('REAL CLI PASS:', out)
    finally:
        # Only this test's isolated canonical job namespace is considered.
        own_store = out / 'data/claude-code-router/jobs'
        jobs = set(jobs) | {path.name for path in own_store.glob('ccr-*') if path.is_dir()}
        for job in jobs:
            with contextlib.suppress(subprocess.SubprocessError):
                run(['ccr', 'cancel', job, '--json'], check=False, timeout=15)
        provider.close()
        if sentinel is not None:
            if sentinel.poll() is None:
                # The Popen child created this new session/group and remains
                # unreaped; its PID cannot be reused. Never signal group 0/1.
                assert sentinel.pid > 1 and os.getpgid(sentinel.pid) == sentinel.pid
                os.killpg(sentinel.pid, signal.SIGTERM)
                sentinel.wait(timeout=10)
            if sentinel_fd is not None:
                os.close(sentinel_fd)
        for process in processes:
            if process.poll() is None:
                process.kill()  # Only exact test-owned collector handles.
                process.wait(timeout=5)


if __name__ == '__main__':
    main()
