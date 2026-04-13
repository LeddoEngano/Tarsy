from playwright.sync_api import sync_playwright
import sys

url = sys.argv[1] if len(sys.argv) > 1 else 'https://tarsy.dev'
output = sys.argv[2] if len(sys.argv) > 2 else '/tmp/fullpage.png'
w = int(sys.argv[3]) if len(sys.argv) > 3 else 1920
h = int(sys.argv[4]) if len(sys.argv) > 4 else 1080

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={'width': w, 'height': h})
    page.goto(url, wait_until='networkidle')
    page.screenshot(path=output, full_page=True)
    browser.close()
    print(f"Full-page screenshot saved to {output}")
