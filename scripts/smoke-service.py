#!/usr/bin/env python3
"""Run an isolated, unprivileged daemon and exercise real HTTP/restart behavior.

Never installs a launch service, edits OS accounts, or enables a network filter.
"""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
candidates = [ROOT / '.build/out/Products/Debug/kids-quota-service', ROOT / '.build/debug/kids-quota-service']
binary = Path(os.environ['KIDS_QUOTA_SERVICE_BINARY']) if 'KIDS_QUOTA_SERVICE_BINARY' in os.environ else next((p for p in candidates if p.is_file()), None)
if not binary:
    raise SystemExit('Build first with swift build or scripts/build-macos.sh --unsigned.')

with tempfile.TemporaryDirectory(prefix='kq-smoke-', dir='/private/tmp') as temporary:
    folder = Path(temporary)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    command = [str(binary), '--development', '--data-dir', str(folder), '--socket', str(folder / 'native.sock'), '--port', str(port)]
    log = (folder / 'service.log').open('wb')
    process = None
    subprocess.run(command + ['--init'], stdout=log, stderr=log, check=True)
    # Prepare test-only persistent policy offline. HTTP is intentionally read-only
    # even with the bootstrap token; real mutations need OS-authorized parent IPC.
    with sqlite3.connect(folder / 'quota.sqlite') as database:
        policy = json.loads(database.execute("SELECT value FROM metadata WHERE key='policy'").fetchone()[0])
        policy['revision'] = 1
        policy['services'].append({'id':'smoke-reading','name':'Books','domains':[{'hostname':'example.org','includeSubdomains':True}],'applicationIds':[]})
        database.execute("UPDATE metadata SET value=? WHERE key='policy'",(json.dumps(policy).encode(),))

    def start():
        global process
        process = subprocess.Popen(command, stdout=log, stderr=log)
        for _ in range(100):
            if process.poll() is not None:
                raise AssertionError('Daemon exited; inspect the build before running this smoke test.')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    return
            except OSError:
                time.sleep(.05)
        raise AssertionError('Daemon did not listen in time.')

    def stop(crash=False):
        if process and process.poll() is None:
            process.kill() if crash else process.terminate()
            process.wait(timeout=5)

    def request(method, path, body=None, token=None, extra=None):
        headers = {'Authorization': 'Bearer ' + (token if token is not None else parent_token)}
        if extra:
            headers.update(extra)
        data = None if body is None else json.dumps(body).encode()
        if data is not None:
            headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(f'http://127.0.0.1:{port}/v1' + path, data=data, headers=headers, method=method)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            assert response.headers['Cache-Control'] == 'no-store'
            return response.status, json.load(response)

    try:
        start()
        parent_token = (folder / 'admin.token').read_text().strip()
        assert request('GET', '/children', token='wrong')[0] == 401
        assert request('GET', '/children', extra={'Origin': 'https://example.org'})[0] == 403
        assert request('GET', '/children', extra={'Host': 'evil.example'})[0] == 403
        status, children = request('GET', '/children')
        assert status == 200 and children['items'] == []
        revision = children['policyRevision']
        status, _ = request('POST', '/services', {
            'expectedPolicyRevision': revision, 'name': 'Reading',
            'domains': [{'hostname': 'example.org', 'includeSubdomains': True}], 'applicationIds': []})
        assert status == 403
        assert request('GET', '/admin/state')[0] == 403
        assert request('PATCH', '/services/smoke-reading', {'expectedPolicyRevision':revision,'name':'Forbidden'})[0] == 403
        assert request('POST', '/admin/children/not-a-child/reset', {'expectedPolicyRevision':revision})[0] == 403
        assert request('POST', '/usage', {'seconds': 999})[0] == 404
        with socket.create_connection(('127.0.0.1', port), timeout=3) as connection:
            connection.sendall(b'POST /v1/services HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n')
            assert connection.recv(1024).startswith(b'HTTP/1.1 400')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect(str(folder / 'native.sock'))
            connection.sendall(b'{"op":"filterRules"}\n')
            assert b'rejected' in connection.recv(1024)
        stop(crash=True)
        start()  # Recovers SQLite and its own stale UNIX socket after a crash.
        status, services = request('GET', '/services')
        assert status == 200 and any(item['name'] == 'Books' for item in services['items'])
        assert services['policyRevision'] == revision
        assert (folder / 'admin.token').read_text().strip() == parent_token
        print('PASS: live HTTP auth, Origin/Host protection, administrator-only mutation boundary, framing, native peer rejection, crash recovery and persistence.')
    finally:
        stop()
        log.close()
