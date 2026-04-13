# Third-Party Notices

This project includes or depends on the following third-party software:

---

## fishhook

- **Source:** `TarsymacOS/Sources/HotReload/Dylib/fishhook.c`, `fishhook.h`
- **License:** BSD 3-Clause
- **Copyright:** Copyright (c) 2013, Facebook, Inc.
- **URL:** https://github.com/facebook/fishhook

Used for runtime function hooking in the macOS hot-reload system.

```
Copyright (c) 2013, Facebook, Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

  * Neither the name Facebook nor the names of its contributors may be used to
    endorse or promote products derived from this software without specific
    prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## Swift Package Dependencies

These are fetched via Swift Package Manager at build time:

| Package | License | URL |
|---------|---------|-----|
| supabase-swift | Apache 2.0 | https://github.com/supabase/supabase-swift |

## npm Dependencies

These are fetched via npm at install time. See `relay/package.json` and `website/package.json` for full lists.

| Package | License | Used In |
|---------|---------|---------|
| hono | MIT | Relay server |
| @supabase/supabase-js | Apache 2.0 | Relay, Website |
| next | MIT | Website |
| react | MIT | Website |
| tailwindcss | MIT | Website |
| framer-motion | MIT | Website |
| xterm | MIT | Website |

## Fonts

| Font | License |
|------|---------|
| Inter Variable | SIL Open Font License 1.1 |
