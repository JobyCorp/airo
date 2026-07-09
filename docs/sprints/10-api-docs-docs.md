# S10 — API docs (`/docs`)

**Status:** [x] done  
**Branch:** `sprint/10-api-docs-docs`  

## Scope

A Swagger UI reference at `/docs` (like Infinity's), backed by the existing
`open_api_spex` document at `/openapi`.
- `get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/openapi"`; nav link; `/docs` open (LAN), Bearer authorize for try-it-out
- Enrich `AiroWeb.ApiSpec`: add the missing `/v1/classify` path; add request/response **schemas + examples** for every endpoint, the `route` object (`class`/`tools`/`vision`), and `capabilities` on `/v1/models`
- Decide CSP/offline: vendor Swagger UI assets into `priv/static` vs CDN (LAN browsers need internet for the CDN)
- **DoD extra:** `/docs` renders every `/v1` path with request/response detail; "Authorize" + try-it-out works against a real key
