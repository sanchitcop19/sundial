#!/usr/bin/env python3
"""Points Xcode Cloud at main and sends every build to TestFlight.

Run once, after Xcode has created the Xcode Cloud product for this app
(Xcode > Integrate > Create Workflow). Apple's API can't create the app record
or the product itself, but it can do everything after that:

  * a "TestFlight" workflow that archives the iOS app whenever main changes
    under ios/ or the shared core, and uploads it for internal testing;
  * an internal TestFlight group, open to every build, holding every
    App Store Connect user on the team, so builds reach your phone unattended.

Safe to re-run: it updates what is already there.

Needs APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID and
APP_STORE_CONNECT_PRIVATE_KEY (the .p8 contents) in the environment, and
`pip install pyjwt cryptography`.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

BUNDLE_ID = "dev.sanchit.sundial.mobile"
REPO = "sundial"
WORKFLOW = "TestFlight"
GROUP = "Phone"
API = "https://api.appstoreconnect.apple.com"


def _key():
    k = os.environ["APP_STORE_CONNECT_PRIVATE_KEY"].replace("\\n", "\n")
    if "BEGIN" not in k:
        k = f"-----BEGIN PRIVATE KEY-----\n{k.strip()}\n-----END PRIVATE KEY-----\n"
    return k


def call(method, path, body=None):
    now = int(time.time())
    token = jwt.encode(
        {"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"], "iat": now,
         "exp": now + 1100, "aud": "appstoreconnect-v1"},
        _key(), algorithm="ES256",
        headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"], "typ": "JWT"})
    req = urllib.request.Request(
        path if path.startswith("http") else API + path, method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            text = r.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} failed ({e.code}): {e.read().decode()[:800]}")


def die(msg):
    sys.exit("error: " + msg)


def main():
    apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        die(f"no App Store Connect app for {BUNDLE_ID}. Create it with Xcode's "
            "Create Workflow, or at appstoreconnect.apple.com > Apps > +.")
    app = apps[0]["id"]

    product = call("GET", f"/v1/apps/{app}/ciProduct").get("data")
    if not product:
        die("no Xcode Cloud product for this app yet. In Xcode: Integrate > Create Workflow.")
    product = product["id"]

    repos = [r for r in call("GET", "/v1/scmRepositories?limit=200")["data"]
             if r["attributes"]["repositoryName"] == REPO]
    if not repos:
        die(f"Xcode Cloud cannot see the {REPO} repository. Grant its GitHub app access.")
    repo = repos[0]["id"]

    versions = call("GET", "/v1/ciXcodeVersions?include=macOsVersions&limit=50")
    xcode = next(v for v in versions["data"] if v["attributes"]["name"] == "Latest Release")
    macos = next(m for m in versions["included"]
                 if m["type"] == "ciMacOsVersions" and m["attributes"]["name"] == "Latest Release")

    attributes = {
        "name": WORKFLOW,
        "description": "Archives the iOS app on every change to main and sends it to TestFlight.",
        "isEnabled": True,
        "isLockedForEditing": False,
        "clean": False,
        "containerFilePath": "ios/SundialMobile.xcodeproj",
        "branchStartCondition": {
            "source": {"isAllMatch": False,
                       "patterns": [{"pattern": "main", "isPrefix": False}]},
            "filesAndFoldersRule": {
                "mode": "START_IF_ANY_FILE_MATCHES",
                "matchers": [{"directory": "ios"},
                             {"directory": "Sources/SundialCore"},
                             {"fileName": "Package.swift"}]},
            "autoCancel": True},
        "actions": [{
            "name": "Archive - iOS", "actionType": "ARCHIVE", "platform": "IOS",
            "scheme": "SundialMobile", "isRequiredToPass": True,
            "buildDistributionAudience": "INTERNAL_ONLY"}],
    }
    relationships = {
        "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": xcode["id"]}},
        "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": macos["id"]}},
    }
    workflows = call("GET", f"/v1/ciProducts/{product}/workflows")["data"]
    # Xcode's wizard leaves a "Default" workflow behind; two would build twice.
    for w in workflows:
        if w["attributes"]["name"] != WORKFLOW and w["attributes"]["isEnabled"]:
            call("PATCH", f"/v1/ciWorkflows/{w['id']}", {"data": {
                "type": "ciWorkflows", "id": w["id"], "attributes": {"isEnabled": False}}})
            print(f"Disabled workflow {w['attributes']['name']}")
    existing = [w for w in workflows if w["attributes"]["name"] == WORKFLOW]
    if existing:
        wf = existing[0]["id"]
        call("PATCH", f"/v1/ciWorkflows/{wf}", {"data": {
            "type": "ciWorkflows", "id": wf, "attributes": attributes,
            "relationships": relationships}})
        print(f"Updated workflow {WORKFLOW}")
    else:
        relationships["product"] = {"data": {"type": "ciProducts", "id": product}}
        relationships["repository"] = {"data": {"type": "scmRepositories", "id": repo}}
        wf = call("POST", "/v1/ciWorkflows", {"data": {
            "type": "ciWorkflows", "attributes": attributes,
            "relationships": relationships}})["data"]["id"]
        print(f"Created workflow {WORKFLOW}")

    groups = [g for g in call("GET", f"/v1/apps/{app}/betaGroups")["data"]
              if g["attributes"]["name"] == GROUP]
    if groups:
        group = groups[0]["id"]
    else:
        group = call("POST", "/v1/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP, "isInternalGroup": True,
                           "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]["id"]
        print(f"Created internal TestFlight group {GROUP}")

    have = {t["attributes"].get("email")
            for t in call("GET", f"/v1/betaGroups/{group}/betaTesters?limit=200")["data"]}
    for user in call("GET", "/v1/users?limit=200")["data"]:
        a = user["attributes"]
        email = a.get("username")
        if not email or email in have:
            continue
        call("POST", "/v1/betaTesters", {"data": {
            "type": "betaTesters",
            "attributes": {"email": email, "firstName": a.get("firstName") or "",
                           "lastName": a.get("lastName") or ""},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group}]}}}})
        print(f"Added {a.get('firstName') or email} to {GROUP}")

    refs = call("GET", f"/v1/scmRepositories/{repo}/gitReferences?limit=200")["data"]
    main_ref = next(r["id"] for r in refs if r["attributes"]["canonicalName"] == "refs/heads/main")
    call("POST", "/v1/ciBuildRuns", {"data": {
        "type": "ciBuildRuns",
        "relationships": {
            "workflow": {"data": {"type": "ciWorkflows", "id": wf}},
            "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": main_ref}}}}})
    print("Started a first build. It will show up in TestFlight on your phone when it finishes.")


if __name__ == "__main__":
    main()
