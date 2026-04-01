# Proposal: Testing for the Web Stack

**Status:** Pending
**Scope:** `web/` repo -- AckWeb.Api, AckWeb.Client.Aha, AckWeb.Client.Wol, personal React SPA
**Related:** web-blazor-spa.md (active)

---

## Problem

The new web stack has no automated tests. The API contains non-trivial logic (path traversal prevention, lore entry extraction) that is untested. The Blazor components have interactive state that is untested. The React SPA has no tests at all. Any regression in these areas would only be caught in production.

---

## Approach

### 1. `AckWeb.Tests` -- .NET test project (xunit + bUnit)

New project `AckWeb.Tests/` added to `AckWeb.sln`. Covers:

#### Unit tests -- `AckWeb.Api`

The two pure-logic helpers currently written as local functions in `Program.cs` are moved into an `internal static class ReferenceHelpers` in a separate file (`AckWeb.Api/ReferenceHelpers.cs`), making them callable from test code via `InternalsVisibleTo`.

| Test | What it verifies |
|---|---|
| `SafeTopicPath_ReturnsNull_WhenTopicEmpty` | Empty/whitespace topic returns null |
| `SafeTopicPath_ReturnsNull_WhenFileDoesNotExist` | Missing file returns null |
| `SafeTopicPath_ReturnsNull_WhenPathTraversesOutside` | `../../etc/passwd` returns null |
| `SafeTopicPath_ReturnsPath_WhenValid` | Valid topic returns resolved path |
| `ExtractFirstLoreEntry_ReturnsFullContent_WhenNoKeywordsHeader` | Fallback: no header → return all |
| `ExtractFirstLoreEntry_ReturnsFirstEntry_WhenKeywordsHeaderPresent` | Standard lore format → first entry only |
| `ExtractFirstLoreEntry_ReturnsEmpty_WhenKeywordsHeaderIsLast` | Edge: keywords block is last → empty |

#### Integration tests -- `AckWeb.Api`

Using `Microsoft.AspNetCore.Mvc.Testing` (`WebApplicationFactory<Program>`). The game server HTTP client is replaced by a `FakeHttpMessageHandler` that returns canned responses.

| Test | What it verifies |
|---|---|
| `GET /api/who` returns 200 with HTML | Happy path |
| `GET /api/who` returns fallback HTML when game server fails | Error path |
| `GET /api/gsgp` returns 200 JSON | Happy path |
| `GET /api/gsgp` returns fallback JSON when game server fails | Error path |
| `GET /api/reference/help` returns 200 JSON array | Lists topics from temp dir |
| `GET /api/reference/help?q=fire` returns filtered array | Query filter works |
| `GET /api/reference/help/{topic}` returns 200 plain text | Reads file content |
| `GET /api/reference/help/../../etc/passwd` returns 404 | Path traversal blocked |
| `GET /api/reference/lore/{topic}` returns first entry only | Lore extraction applied |
| `GET /api/reference/unknown/{topic}` returns 404 | Unknown topic returns 404 |

Integration tests use a `TempDirectory` fixture that creates real files on disk so the API reads them correctly.

#### Component tests -- Blazor (bUnit)

Using `bUnit` (`Bunit` NuGet package).

| Test | Component | What it verifies |
|---|---|---|
| `StoryCard_RendersCollapsed_ByDefault` | `StoryCard` | Story body not visible initially |
| `StoryCard_OpensOnHeaderClick` | `StoryCard` | Clicking header reveals body |
| `StoryCard_ClosesOnSecondClick` | `StoryCard` | Toggle closes again |
| `StoryCard_RendersEraAndTitle` | `StoryCard` | Parameters rendered correctly |
| `Reference_DefaultsToHelpTab` | `Reference` | No `Tab` param → active tab is "help" |
| `Reference_ShowsShelpTab_WhenTabIsShelpParam` | `Reference` | Tab param routes correctly |

---

### 2. Personal React SPA -- Vitest + React Testing Library

Add test infrastructure to `personal/`:

- **Vitest** (fast Vite-native test runner, zero config with existing `vite.config.ts`)
- **`@testing-library/react`** + **`@testing-library/user-event`** for component testing
- **`jsdom`** as the test environment

#### Unit / component tests

| Test | What it verifies |
|---|---|
| `renders avatar initials` | "JB" initials element is present |
| `renders name heading` | `<h1>Jared Bailes</h1>` is rendered |
| `renders GitHub link` | Link with correct href and text |
| `renders LinkedIn link` | Link with correct href and text |
| `all external links have target=_blank and rel=noopener` | Security attribute check |
| `glow element is aria-hidden` | Decorative element not exposed to screen readers |

No integration tests are needed for the personal site -- it has no API calls or routing.

---

## Affected files

| File | Action |
|---|---|
| `AckWeb.Tests/AckWeb.Tests.csproj` | Create |
| `AckWeb.Tests/Api/ReferenceHelpersTests.cs` | Create |
| `AckWeb.Tests/Api/ApiIntegrationTests.cs` | Create |
| `AckWeb.Tests/Components/StoryCardTests.cs` | Create |
| `AckWeb.Tests/Components/ReferenceTests.cs` | Create |
| `AckWeb.Api/ReferenceHelpers.cs` | Create (extract helpers from Program.cs) |
| `AckWeb.Api/Program.cs` | Update (use ReferenceHelpers, add InternalsVisibleTo) |
| `AckWeb.Api/AckWeb.Api.csproj` | Update (add InternalsVisibleTo attribute) |
| `AckWeb.sln` | Update (add AckWeb.Tests project) |
| `personal/package.json` | Update (add vitest, testing-library deps) |
| `personal/vite.config.ts` | Update (add vitest config block) |
| `personal/src/App.test.tsx` | Create |
| `setup.sh` | Update (add `dotnet test` and `npm test` steps) |

---

## Trade-offs

- **bUnit vs Playwright:** bUnit tests Blazor component logic in process (fast, no browser needed). Playwright would test full browser rendering but requires a running server and is much slower. bUnit is the right level for component unit tests; Playwright can be added later.
- **Vitest vs Jest:** Vitest reuses the existing Vite config with zero additional tooling. Jest would require a separate babel/ts config. Vitest is the natural choice here.
- **InternalsVisibleTo:** Exposing internals to the test assembly is a standard .NET testing pattern and does not affect the public API surface.
- **No Blazor WASM browser tests:** End-to-end browser tests for the WASM apps are deferred. bUnit covers the component logic that matters most (StoryCard toggle, Reference tab routing).
