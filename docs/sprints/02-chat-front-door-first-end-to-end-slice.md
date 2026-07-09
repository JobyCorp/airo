# S2 — Chat front door (first end-to-end slice)

**Status:** [x] done  
**Branch:** `sprint/02-chat-front-door-first-end-to-end-slice`  

## Scope

- `POST /v1/chat/completions` (non-streaming): alias → normalize → adapter → response
- Client-key auth plug (hashed lookup, `allowed_aliases` scope)
- Param normalization v1: layered defaults (provider<deployment<alias<request),
  `provider_params` passthrough, unknown-key passthrough (DESIGN §7)
- **DoD extra:** real request against a local vLLM/Ollama succeeds
