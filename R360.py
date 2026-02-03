#!/usr/bin/env python3
# Attach to the already-running kiosk Chromium via CDP and perform the login.
# Uses your existing selectors (name= fields).

from pathlib import Path
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

CREDS_PATH = "/etc/cadtv/credentials.env"
CDP_URL = "http://127.0.0.1:9222"

def load_env(path: str) -> dict:
    data = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data

def type_if_present(field_name: str, value: str, delay: int = 20) -> None:
    if not value:
        return
    loc = page.locator(f'input[name="{field_name}"]')
    if loc.count() == 0:
        return
    loc = loc.first
    loc.click()
    loc.press("Control+A")
    loc.type(value, delay=delay)  

cfg = load_env(CREDS_PATH)
URL = cfg["URL"]
USERNAME = cfg["USERNAME"]
PASSWORD = cfg["PASSWORD"]
AGENCY = cfg.get("AGENCY", "springfd")
UNIT = cfg.get("UNIT", "")
BoardID = cfg.get("BoardID", "Admin")
KEEP_LOGGED_IN = cfg.get("KEEP_LOGGED_IN", "1") in ("1", "true", "True", "yes", "YES")

def is_still_on_login(page) -> bool:
    return page.locator('input[name="username"]').count() > 0

with sync_playwright() as p:
    browser = p.chromium.connect_over_cdp(CDP_URL)
    context = browser.contexts[0] if browser.contexts else browser.new_context()
    page = context.pages[0] if context.pages else context.new_page()

    page.goto(URL, wait_until="domcontentloaded")
    page.wait_for_selector('input[name="username"]', timeout=30000)

    # Type into fields to trigger ExtJS listeners
    u = page.locator('input[name="username"]')
    u.click()
    u.press("Control+A")
    u.type(USERNAME, delay=25)

    pw = page.locator('input[name="password"]')
    pw.click()
    pw.press("Control+A")
    pw.type(PASSWORD, delay=25)

    if AGENCY:
        a = page.locator('input[name="agency"]')
        a.click()
        a.press("Control+A")
        a.type(AGENCY, delay=20)

    type_if_present("stationboard_uid", BoardID, delay=20)
    type_if_present("unit", UNIT, delay=20)

    if KEEP_LOGGED_IN:
        cb = page.locator('input[name="rememberMe"]')
        if cb.count() and not cb.is_checked():
            cb.check()

    # Retry submit a few times
    for attempt in range(1, 6):
        # Wait until ExtJS enables the login button
        try:
            page.wait_for_function(
                """() => {
                    const btn = document.querySelector('[data-componentid="ext-button-1"]');
                    const inner = btn ? btn.querySelector('button.x-button-el') : null;
                    return inner && !inner.disabled;
                }""",
                timeout=15000,
            )
        except PWTimeout:
            pass

        # 1) Real click on wrapper (ExtJS listens here)
        try:
            wrapper = page.locator('[data-componentid="ext-button-1"]')
            wrapper.scroll_into_view_if_needed()
            wrapper.hover()
            wrapper.click(force=True)
            page.wait_for_timeout(800)
        except Exception:
            pass

        if not is_still_on_login(page):
            break

        # 2) Enter key fallback
        try:
            pw.focus()
            pw.press("Enter")
            page.wait_for_timeout(800)
        except Exception:
            pass

        if not is_still_on_login(page):
            break

        # 3) JS click fallback
        page.evaluate("""() => {
            const root = document.querySelector('[data-componentid="ext-button-1"]');
            const btn = root ? root.querySelector('button.x-button-el') : null;
            if (btn && !btn.disabled) btn.click();
        }""")
        page.wait_for_timeout(800)

        if not is_still_on_login(page):
            break

        # Small pause before next attempt
        page.wait_for_timeout(1200)

    # Optional: wait for SPA to settle
    try:
        page.wait_for_load_state("networkidle", timeout=20000)
    except PWTimeout:
        pass
    # Save cookies if you want
    context.storage_state(path="/home/cadtv/.config/r360_storage.json")

    page.wait_for_timeout(30000)
