#!/usr/bin/env python3
"""Read balances with a scoped token from Settings, never the administrator token."""
import argparse
import json
import os
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('child_id', help='An ID from GET /v1/children granted to this client')
args = parser.parse_args()
token = os.environ.get('KIDS_QUOTA_READ_TOKEN')
if not token:
    parser.error('Set KIDS_QUOTA_READ_TOKEN to a read token created in Settings.')
url = 'http://127.0.0.1:48123/v1/children/' + urllib.parse.quote(args.child_id, safe='') + '/balances'
request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
with urllib.request.urlopen(request, timeout=5) as response:
    print(json.dumps(json.load(response), indent=2))
