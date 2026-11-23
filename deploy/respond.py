import json
import os
import sys
import time
import urllib.request as ur


def rd(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


status = rd("/tmp/status")
if status not in ("SUCCESS", "FAILED"):
    status = "FAILED"
reason = rd("/tmp/reason")
if not reason:
    reason = "Deployer build did not complete"
if status == "FAILED":
    reason = "%s (build %s)" % (reason, os.environ.get("CODEBUILD_BUILD_ID", "unknown"))
data = {}
if (status == "SUCCESS" and os.environ.get("STAGE") == "app"
        and os.environ.get("REQUEST_TYPE") in ("Create", "Update")):
    data["AlbHostname"] = rd("/tmp/alb_host")
url = os.environ.get("RESPONSE_URL", "")
if not url:
    print("RESPONSE_URL is not set; cannot respond. status=%s reason=%s" % (status, reason))
    sys.exit(1)
body = json.dumps({
    "Status": status,
    "Reason": reason[:1000],
    "PhysicalResourceId": os.environ.get("PHYSICAL_ID") or os.environ["LOGICAL_RESOURCE_ID"],
    "StackId": os.environ["STACK_ID"],
    "RequestId": os.environ["REQUEST_ID"],
    "LogicalResourceId": os.environ["LOGICAL_RESOURCE_ID"],
    "Data": data,
}).encode()
last = None
for attempt in range(5):
    try:
        req = ur.Request(url, data=body, method="PUT", headers={"Content-Type": ""})
        print("Response sent, HTTP %s: %s" % (ur.urlopen(req, timeout=30).status, status))
        sys.exit(0)
    except SystemExit:
        raise
    except Exception as ex:
        last = ex
        print("PUT attempt %d failed: %s" % (attempt + 1, ex))
        time.sleep(5)
print("Could not send the response: %s" % last)
sys.exit(1)
