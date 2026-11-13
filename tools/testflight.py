#!/usr/bin/env python3
"""Clamshell on TestFlight (internal testing only, no beta review needed).

    tools/testflight.py status      # app record, builds, group and testers
    tools/testflight.py wait [h]    # block until the App Store Connect app record exists (default 10 h)
    tools/testflight.py group       # make the internal "Owner" group (all builds) and add the owner
    tools/testflight.py waitbuild   # block until the newest build finishes processing (30 min)

The app record itself cannot be made here: Apple's API refuses to create apps (403), it needs the website.
Idempotent: safe to rerun.
"""
import sys
import time

from asc import call, setting

BUNDLE = "com.jadenkwek.clamshell"
GROUP = "Owner"
# `group` adds the owner's existing App Store Connect tester record (its id is ASC_OWNER_TESTER,
# from the environment or ~/.config/clamshell/asc.env) to the internal group.


def find_app():
    apps = call("GET", f"apps?filter[bundleId]={BUNDLE}&fields[apps]=name,bundleId,sku,primaryLocale")["data"]
    return apps[0] if apps else None


def app_id():
    app = find_app()
    if not app:
        sys.exit(f"No App Store Connect app for {BUNDLE} yet.")
    return app["id"]


def wait(hours):
    deadline = time.time() + hours * 3600
    while time.time() < deadline:
        try:
            app = find_app()
        except (Exception, SystemExit) as e:  # an API error or a network dropout must not end the wait
            print(f"check failed, will retry: {str(e)[:120]}", flush=True)
            app = None
        if app:
            print(f"app record found: {app['id']} {app['attributes']}", flush=True)
            return
        time.sleep(60)
    sys.exit("gave up waiting for the app record")


def ensure_group(app):
    for g in call("GET", f"apps/{app}/betaGroups")["data"]:
        if g["attributes"]["name"] == GROUP:
            return g
    return call("POST", "betaGroups", {"data": {"type": "betaGroups",
                "attributes": {"name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
                "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]


def group():
    owner = setting("ASC_OWNER_TESTER")
    app = app_id()
    g = ensure_group(app)
    have = [t["id"] for t in call("GET", f"betaGroups/{g['id']}/betaTesters")["data"]]
    if owner not in have:
        # Apple refuses to attach an existing tester id to a new internal group ("Tester(s) cannot be
        # assigned"); creating the tester with Apple's own name and address on that group works.
        who = call("GET", f"betaTesters/{owner}?fields[betaTesters]=firstName,lastName,email")["data"]["attributes"]
        call("POST", "betaTesters", {"data": {"type": "betaTesters",
             "attributes": {k: who[k] for k in ("firstName", "lastName", "email")},
             "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": g["id"]}]}}}})
    print(f"group {GROUP} {g['id']} ready, owner added")


def builds(app):
    return call("GET", f"builds?filter[app]={app}&sort=-uploadedDate&limit=5"
                       "&fields[builds]=version,processingState,uploadedDate,expired,usesNonExemptEncryption")["data"]


def waitbuild():
    app = app_id()
    deadline = time.time() + 30 * 60
    while time.time() < deadline:
        try:
            found = builds(app)
        except (Exception, SystemExit) as e:
            print(f"check failed, will retry: {str(e)[:120]}", flush=True)
            time.sleep(45)
            continue
        if found:
            state = found[0]["attributes"]["processingState"]
            print(f"build {found[0]['attributes']['version']}: {state}", flush=True)
            if state != "PROCESSING":
                sys.exit(0 if state == "VALID" else f"build ended as {state}")
        else:
            print("no build listed yet", flush=True)
        time.sleep(45)
    sys.exit("build still processing after 30 minutes")


def status():
    app = find_app()
    if not app:
        print(f"no app record for {BUNDLE}")
        return
    print(f"app {app['id']} {app['attributes']}")
    for b in builds(app["id"]):
        print(f"  build {b['attributes']}")
    for g in call("GET", f"apps/{app['id']}/betaGroups")["data"]:
        a = g["attributes"]
        testers = call("GET", f"betaGroups/{g['id']}/betaTesters?fields[betaTesters]=state,inviteType")["data"]
        print(f"  group {a['name']} internal={a.get('isInternalGroup')} allBuilds={a.get('hasAccessToAllBuilds')} "
              f"testers={[(t['id'][:8], t['attributes'].get('state')) for t in testers]}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "wait":
        wait(float(sys.argv[2]) if len(sys.argv) > 2 else 10)
    elif cmd == "group":
        group()
    elif cmd == "waitbuild":
        waitbuild()
    else:
        status()
