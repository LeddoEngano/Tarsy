from playwright.sync_api import sync_playwright
import json

URL = 'https://tarsy.dev'

def analyze(viewport_width, viewport_height, label):
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={'width': viewport_width, 'height': viewport_height})
        page.goto(URL, wait_until='networkidle')

        results = page.evaluate("""() => {
            const vw = window.innerWidth;
            const vh = window.innerHeight;

            function getInfo(selector) {
                const el = document.querySelector(selector);
                if (!el) return null;
                const rect = el.getBoundingClientRect();
                const style = window.getComputedStyle(el);
                return {
                    text: el.innerText ? el.innerText.trim().slice(0, 100) : '',
                    rect: { top: rect.top, left: rect.left, bottom: rect.bottom, right: rect.right, width: rect.width, height: rect.height },
                    aboveFold: rect.bottom > 0 && rect.top < vh,
                    fontSize: style.fontSize,
                    display: style.display,
                    visible: rect.width > 0 && rect.height > 0
                };
            }

            function hasHorizontalScroll() {
                return document.documentElement.scrollWidth > document.documentElement.clientWidth;
            }

            const h1 = getInfo('h1');
            const mainCta = getInfo('a[href*="download"], a[href*="app-store"], a[href*="apps.apple"], button');
            const nav = getInfo('nav');
            const hero = getInfo('section, .hero, header');
            const heroImg = getInfo('img, video');

            // Check all buttons/links for touch target size
            const allLinks = Array.from(document.querySelectorAll('a, button')).map(el => {
                const rect = el.getBoundingClientRect();
                return {
                    text: el.innerText ? el.innerText.trim().slice(0, 50) : el.href || '',
                    width: rect.width,
                    height: rect.height,
                    tooSmall: rect.width < 44 || rect.height < 44
                };
            }).filter(el => el.width > 0 && el.height > 0);

            // Check for overflowing elements
            const overflowing = Array.from(document.querySelectorAll('*')).filter(el => {
                const rect = el.getBoundingClientRect();
                return rect.right > vw + 5;
            }).map(el => ({ tag: el.tagName, class: el.className ? el.className.toString().slice(0, 50) : '', right: el.getBoundingClientRect().right })).slice(0, 10);

            return {
                viewport: { width: vw, height: vh },
                horizontalScroll: hasHorizontalScroll(),
                h1: h1,
                mainCta: mainCta,
                nav: nav,
                hero: hero,
                heroImg: heroImg,
                touchTargets: allLinks,
                overflowingElements: overflowing,
                pageTitle: document.title,
                metaViewport: document.querySelector('meta[name="viewport"]') ? document.querySelector('meta[name="viewport"]').content : null
            };
        }""")

        browser.close()
        return results

for label, w, h in [('desktop', 1920, 1080), ('laptop', 1366, 768), ('tablet', 768, 1024), ('mobile', 375, 812)]:
    print(f"\n{'='*60}")
    print(f"VIEWPORT: {label.upper()} ({w}x{h})")
    print('='*60)
    data = analyze(w, h, label)
    print(f"Page title: {data['pageTitle']}")
    print(f"Meta viewport: {data['metaViewport']}")
    print(f"Horizontal scroll: {data['horizontalScroll']}")
    print(f"Overflowing elements: {len(data['overflowingElements'])}")
    for ov in data['overflowingElements']:
        print(f"  - <{ov['tag']}> class='{ov['class']}' right={ov['right']:.0f}px")

    if data['h1']:
        h1 = data['h1']
        print(f"\nH1: '{h1['text'][:60]}'")
        print(f"  Font size: {h1['fontSize']}, Above fold: {h1['aboveFold']}, Visible: {h1['visible']}")
        print(f"  Position: top={h1['rect']['top']:.0f} left={h1['rect']['left']:.0f} w={h1['rect']['width']:.0f} h={h1['rect']['height']:.0f}")
    else:
        print("\nH1: NOT FOUND")

    if data['mainCta']:
        cta = data['mainCta']
        print(f"\nMain CTA: '{cta['text'][:60]}'")
        print(f"  Above fold: {cta['aboveFold']}, Visible: {cta['visible']}")
        print(f"  Position: top={cta['rect']['top']:.0f} bottom={cta['rect']['bottom']:.0f}")
    else:
        print("\nMain CTA: NOT FOUND")

    if data['nav']:
        nav = data['nav']
        print(f"\nNav: visible={nav['visible']}, display={nav['display']}, height={nav['rect']['height']:.0f}px")

    print(f"\nTouch targets ({len(data['touchTargets'])} total):")
    small = [t for t in data['touchTargets'] if t['tooSmall']]
    ok = [t for t in data['touchTargets'] if not t['tooSmall']]
    print(f"  OK (>=44px): {len(ok)}")
    print(f"  Too small (<44px): {len(small)}")
    for t in small[:8]:
        print(f"    '{t['text'][:40]}' {t['width']:.0f}x{t['height']:.0f}px")
