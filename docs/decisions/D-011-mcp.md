# D-011: how the OS maps onto the Model Context Protocol

Status: D-011 (MCP as the agent interface standard) is **Decided** (`docs/spec.md` §5). This write-up describes how the OS maps onto it. It decides nothing new: every "recommendation" below is a proposal for the owner, and the permission model itself is D-012 (#32).
Card: #31 · Facts checked: 2026-11-05 · MCP revision used: **2026-07-28** (the revision marked *Current* on modelcontextprotocol.io on 2026-11-05) [1]

Terms are used as in the glossary (`docs/spec.md` §11): **Assistant**, **Agent interface**, **Permission broker**, **Action log**, **Stop switch**. "Server" and "client" below always mean MCP server and MCP client.

## 1. Summary

- Every assistant talks MCP to exactly one endpoint: the **permission broker**, acting as an MCP gateway. The broker talks MCP to the system servers, app servers, the accessibility bridge and any remote servers the user added. The goal is that no sandboxed assistant reaches a server, the accessibility bus or a portal without going through the broker. Section 6.3 lists the paths that could still bypass it today, and what would close each one.
- Local models are the default and cloud models are opt-in per provider (C10). The security design assumes this; with a cloud model, every tool result the assistant reads leaves the machine (section 6.4).
- Local transport is MCP's own stdio framing (newline-delimited JSON-RPC), carried over a Unix domain socket or over stdio of a spawned process. The spec allows this as a custom transport and asks byte-stream transports to reuse the stdio framing [2]. HTTP is used only for remote servers.
- Discovery reuses D-Bus activation and Flatpak's existing exports. Apps don't need a new portal or a new Flatpak export directory to offer a server (section 4).
- Apps without MCP are operated through the AT-SPI tree by one system **accessibility bridge** server. That only works if the toolkit publishes a complete tree with the right roles, states and actions. Section 5 lists the requirements as input for D-006, using the M6 and M7 findings.
- Recommended Rust SDK: `rmcp`, the official SDK (section 8).
- 18 open questions for D-012 are in section 7.

"Assistant host" below means the process that runs an assistant: its model connection and its MCP client. It may come from us or from a third party.

## 2. The parts of MCP 2026-07-28 that matter here

Checked against the specification [1], the changelog [3] and the schema [4]:

| Fact | Consequence for us |
| --- | --- |
| **Stateless protocol.** No `initialize` handshake and no protocol-level sessions. Every request carries its protocol version and client capabilities in `_meta`. Servers must implement `server/discover` [3]. | A gateway can forward requests one at a time without tracking sessions. Per-call state, such as an open file operation, travels as explicit handles in tool arguments, which the broker can see and log. |
| **Transports:** stdio and Streamable HTTP are standard. Custom transports are allowed if they keep JSON-RPC, the message patterns and the per-request metadata. Byte-stream transports such as Unix sockets "SHOULD reuse the stdio framing" [2]. | A Unix socket carrying stdio framing is spec-conformant and needs no new wire format. |
| **Primitives:** tools (model-controlled), resources (application-controlled data addressed by URI), prompts (user-controlled templates) [1]. | System features expose tools for actions and resources for state. Prompts aren't needed in the first version. |
| **Tool annotations:** `readOnlyHint` (default false), `destructiveHint` (default true), `idempotentHint` (default false), `openWorldHint` (default true). "Clients MUST consider tool annotations to be untrusted unless they come from trusted servers" [4][5]. | The broker can use annotations from servers in the signed image. For third-party servers they are a hint only, never a reason to skip a confirmation. |
| **Multi round-trip requests (MRTR):** instead of calling back into the client, a server returns `resultType: "input_required"` with `inputRequests` (such as `elicitation/create` in `form` or `url` mode). The client retries the request with `inputResponses` [3][5]. | Elicitation from servers passes through the gateway as ordinary results. The broker sees, and can intercept, every question a server asks the user. |
| **Human in the loop:** "there SHOULD always be a human in the loop with the ability to deny tool invocations". Clients SHOULD show which tools are exposed, show visual indicators when tools are invoked, ask for confirmation, show tool inputs before calling, validate results before passing them to the model, and log tool usage [5]. | Matches C12: indicator, confirmation, action log. MCP leaves where to do this to the implementation; for us it is the broker. |
| **Deprecated in 2026-07-28:** Roots, Sampling, Logging and Dynamic Client Registration, earliest removal in the first revision on or after 2027-07-28. Also the HTTP+SSE transport, earliest removal three months after SEP-2596 reaches Final [6]. | Don't build on them. File scopes go in tool arguments or server configuration, not Roots. Servers never call a model through the client (no Sampling). |
| **Tasks** moved to an official extension (`io.modelcontextprotocol/tasks`), polled with `tasks/get` [3]. | Fits long jobs such as a large copy. The stop switch must cancel them as well (section 6). |
| **Local server compromise** (security best practices): one-click server install MUST show the exact command and ask for consent. Servers SHOULD run sandboxed with minimal privileges, and local servers SHOULD use stdio or IPC with restricted access rather than open HTTP [7]. | Supports the sandboxing in C12 and the transport choice in section 4. |

## 3. Which system features become MCP servers

C12 lists settings, files, windows, notifications, search and connectivity, plus native apps. Each server below belongs to the component that already owns the feature, so it adds a thin MCP front end to existing code and APIs instead of a second implementation. Names are working titles, not decisions.

First tools and resources: the smallest useful set, so the D-012 model can be tried on real cases. "Class" is the annotation the server would declare: **R** = `readOnlyHint: true`; **W** = writes, additive or reversible (`destructiveHint: false`); **D** = destructive or irreversible; **O** = `openWorldHint: true` (reaches outside the machine or other people). Per C12, D and O always need confirmation; how R and W are handled is for D-012. **R doesn't mean free.** With a cloud model, every R result the assistant reads is sent to the provider, so C12 ("data leaving the machine always needs confirmation") and C10's preview apply to it (section 6.4).

| Server (owner) | Backed by | First tools (class) | First resources |
| --- | --- | --- | --- |
| **Settings** (C8) | The config files (D-010) and the same schema the `os` CLI mirrors (C7) | `settings.search` (R), `settings.get` (R), `settings.set` (W; D for security- or privacy-relevant keys), `settings.open_page` (R, opens Settings for the user) | The settings schema with descriptions; current values per page |
| **Files** (C5 Files / C6) | File operations that Files can undo (C5) | `files.list` (R), `files.stat` (R), `files.search` (R, through C6), `files.read_text` (R), `files.create_folder` (W), `files.copy`, `files.move`, `files.rename` (W, undoable), `files.trash` (W, reversible), `files.delete_permanently` (D), `files.open` (W, opens in the default app; **D** for executables, scripts, `.desktop` files and URLs, because these hand control to code outside the broker) | `file://` URIs, limited to the folders granted to the assistant |
| **Windows** (C2/C3) | Compositor and shell state | `windows.list` (R), `windows.focus` (W), `windows.move_to_workspace` (W), `windows.set_window_mode` (W), `windows.close` (D: may lose unsaved work) | Window and workspace list |
| **Apps** (C3/C7) | Desktop entries, D-Bus activation | `apps.list` (R), `apps.launch` (W without arguments; **D** with arguments, files or URLs, as for `files.open`), `apps.quit` (D) | Installed apps with their declared servers |
| **Notifications** (C3) | `org.freedesktop.Notifications` [8] | `notifications.send` (W), `notifications.list` (R, sensitive: other apps' messages) | None at first |
| **Search** (C6) | The system index | `search.query` (R) over apps, files, settings and commands | None |
| **Connectivity** (C9) | NetworkManager, BlueZ, PipeWire over D-Bus | `wifi.list` (R), `wifi.connect` (W; O when it joins a network not seen before), `bluetooth.list` (R), `bluetooth.pair` (O), `audio.set_output` (W), `audio.set_volume` (W) | Current network, devices, audio routes |
| **Accessibility bridge** (C12) | AT-SPI over D-Bus | See section 5 | The accessibility tree of a window the assistant was granted |
| **Native apps** (C5) | Each app's action registry (section 5.3) | Per app, generated from the app's own actions | Per app (such as the open document) |

Left out of the first set on purpose, because each is sensitive under C10 and needs D-012 first: screen contents, camera, microphone, clipboard reading, passwords and keyrings, and installing or removing software (C7). A shell server that runs commands is out by C12 ("no root or unrestricted shell access by default").

Built on this, but outside the first version: the command palette (C3) and the assistant could share one action catalogue, because both list "every action". That is a separate design question for C3 and isn't proposed here.

## 4. Transport and discovery on a desktop

### 4.1 Options

| Option | How it works | For | Against and security risks |
| --- | --- | --- | --- |
| **T1 stdio, spawned** | The client starts the server as a child process and talks over stdin/stdout [2]. | Standard: every MCP client and SDK supports it. Only the parent can talk to the child [7]. A Flatpak server can be started as `flatpak run --command=…` and keeps its sandbox. | System features are long-running daemons (compositor, settings) and can't be a child of each assistant; they would need a small stdio shim. A spawned server runs with the spawner's rights unless it is sandboxed explicitly; the *local server compromise* risk [7] applies to every third-party command. |
| **T2 Unix socket, stdio framing** | A per-user socket under `$XDG_RUNTIME_DIR`, carrying the same newline-delimited JSON-RPC (custom transport [2]). Started by systemd socket activation. | Conformant framing. The kernel identifies the peer (`SO_PEERCRED`, pidfd), so the broker knows which process is calling. File permissions limit who can connect. `rmcp`'s `transport-async-rw` feature takes any async byte stream [9]. | A custom transport: third-party assistants don't speak it, so a stdio-to-socket shim is needed (see 4.2). Peer credentials name a process, not an app: an unsandboxed process can pretend to be another assistant. For Flatpak apps the app ID can be read reliably, as portals do. |
| **T3 MCP inside D-Bus messages** | Each JSON-RPC message is a D-Bus method call or signal. | D-Bus activation, bus credentials and Flatpak's `xdg-dbus-proxy` filtering for free. | Defines a binding nobody else uses. Streaming results fit badly. Bus traffic is visible to bus monitors. No SDK supports it. |
| **T4 Streamable HTTP on localhost** | A local HTTP endpoint. | Every SDK supports it. | Any local process, and any web page via DNS rebinding, can reach it unless it adds origin checks and a token [7]. Not wanted for local servers. Needed only for **remote** servers, which by definition send data off the machine. |

### 4.2 Recommended combination (proposal)

- **Assistant → broker: T2.** One well-known per-user socket. An assistant built with an SDK can use the socket directly. One that can only start a stdio server is configured with a tiny shim binary as its "server command". The shim connects stdio to the socket and does nothing else. Every assistant, ours or third-party, then hits the same enforcement point.
- **Broker → system servers: T2.** One socket per server, and each server serves only the broker. "Only the broker" needs a mechanism, because `SO_PEERCRED` gives the same UID for the broker and for every other process of the user. Two options, for D-012 (Q18):
  - **(i) The broker runs as the user.** Servers check the peer's pidfd: the peer must be the broker binary from the read-only image (D-002), and the broker makes itself non-dumpable so other processes can't ptrace it. A sandboxed assistant can't pass this check. An unsandboxed process of the same user can, by starting the broker binary itself or by ptrace if Yama allows it. That process can already read and change everything the user can, so under (i) unsandboxed same-UID code is outside what the broker protects. C12 requires assistants to be sandboxed.
  - **(ii) The broker runs as its own system user,** one instance per logged-in user (`atos-broker@<uid>`), and servers check the peer UID. This also holds against unsandboxed same-UID code. The cost: the session bus normally accepts only the user's own UID, so the D-Bus handoff in the next point has to run the other way (see there).
- **Broker → app servers: D-Bus for discovery and activation, then T2 over a passed file descriptor.** The app owns a D-Bus name under its app ID, which Flatpak allows without extra permissions, and ships a D-Bus activation file in `share/dbus-1/services`, which Flatpak already exports [10]. The broker calls one method on that name and gets back a socket file descriptor, and MCP runs over that. Portals already hand out file descriptors over D-Bus, for example the ScreenCast portal's PipeWire remote, so this is an existing pattern. **The app must check that the caller is the broker**, because any session-bus peer that can reach the app's name could otherwise call the handoff method and get an MCP connection with no broker in between. That includes any unsandboxed process, and any Flatpak with `--talk-name=<app ID>` or `--socket=session-bus`. Under (i), the C5 skeleton gets the caller's pidfd from the bus (`GetConnectionCredentials`, `ProcessFD`) and applies the same check as the system servers. Under (ii), the direction is reversed: activation over D-Bus only wakes the app and returns nothing, and the app then connects out to the broker's socket. That socket is owned by the broker user, so the app can verify its peer UID. The app serves MCP only on that connection. Exposing the broker socket to Flatpak apps then needs a static permission, which is part of Q13. **Risk:** the broker then trusts what an app's server says about itself. Mitigated by treating every app server's annotations as untrusted (section 2).
- **Broker → third-party stdio servers: T1,** always inside a sandbox. Flatpak apps run with `flatpak run`. Anything else runs under `bubblewrap`, which Flatpak already uses, with no network and no home access unless granted. The consent dialog shows the exact command, as [7] requires.
- **Broker → remote servers: T4,** over HTTPS only. Every call is outbound data (C12: always confirmed). The broker is the MCP client towards the remote server, so MCP Authorization (OAuth 2.1) and the proxy rules in [7] apply to the broker:
  - The broker obtains and holds the tokens. Assistants never see them, and the broker never passes an assistant's token through ([7]: servers "MUST NOT accept any tokens that were not explicitly issued for the MCP server").
  - Client registration uses Client ID Metadata Documents, not the deprecated Dynamic Client Registration [6].
  - Authorization URLs are restricted to `https` (`http` only on loopback) and opened without a shell.
  - SSRF rules apply to every metadata URL a server hands out: block private and link-local ranges, check each redirect [7].
  - Where tokens are stored is open (Q17).

### 4.3 How the broker finds servers

| Source | Mechanism | Needs a change upstream? |
| --- | --- | --- |
| System servers | A manifest per server in the image (read-only, signed per D-002), listing name, socket and owning component | No |
| Flatpak and native apps | A marker in a file the app already exports. Candidates: a key in the desktop entry, or a `<provides>` entry in its AppStream metainfo (both exported [10]). Then D-Bus activation of the app's name | No, but which marker is an open question (section 7, Q14) |
| Third-party stdio servers (npm, pip, binaries) | Added explicitly by the user, with the consent dialog [7] | No |
| Remote servers | Added by URL by the user. The MCP Registry [11] could be a search source in Software (C7) later | No |

Flatpak exports only a fixed list of directories (`share/applications`, `share/icons`, `share/dbus-1/services`, `share/gnome-shell/search-providers`, `share/krunner/dbusplugins`, `share/mime/packages`, `share/metainfo`, `bin`) [10]. A new `share/mcp/` directory would therefore need a Flatpak change. Reusing the desktop entry, metainfo and D-Bus service files avoids that. GNOME Shell search providers (an exported descriptor plus an activatable D-Bus name) are the closest existing precedent.

### 4.4 Flatpak-sandboxed assistants and apps

- **A Flatpak app that offers a server:** see above. No portal is needed, because the broker calls into the app, and Flatpak already lets an app own its own name.
- **A Flatpak assistant that needs to reach the broker:** two options.
  - **(a)** A static `--talk-name=` permission for the broker's D-Bus name. It is shown before install and editable afterwards (C7). Works today with no upstream change. **Risk:** any app can request it, so the broker must still check that the caller is an assistant the user registered.
  - **(b)** A new xdg-desktop-portal interface ("Assistant") that returns a broker connection after a portal dialog. This is the standard way for a sandboxed app to get a privilege, but it needs upstream work or our own portal frontend. No such portal exists today; a search on 2026-11-05 found no proposal.

  Proposal: (a) for Phase 3, and propose (b) upstream once the model has proven itself. That is for D-012 to confirm (section 7, Q13).

## 5. Apps without MCP: the accessibility tree

### 5.1 How it works

One system server, the **accessibility bridge**, reads the AT-SPI bus (D-Bus) and turns it into MCP tools. Proposed first tools:

- `a11y.list_windows` (R)
- `a11y.get_tree(window, depth)` (R): role, name, states, actions and value per node
- `a11y.find(window, role, name)` (R)
- `a11y.do_action(node, action)` (W/D): the AT-SPI `Action` interface, which AccessKit maps to its action requests
- `a11y.set_text(node, text)` (W): `EditableText`
- `a11y.set_value(node, value)` (W): `Value`
- `a11y.select(node)` (W): `Selection`
- `a11y.read_text(node)` (R)

Every call is scoped to one app the user granted, under the same permissions as an MCP server (C12). An action on a node can do anything the control does, so the bridge can't know whether "click *OK*" is destructive. The broker therefore has to treat `a11y.do_action` as unclassified (section 7, Q6).

Synthetic keyboard and mouse input is a last resort, not the default. On Wayland it means the RemoteDesktop portal (libei). It is less precise, can't be scoped to one app, and works on whatever has focus. The same portal is open to any Flatpak, so assistants themselves must be kept from requesting it directly, or the bridge's limits mean nothing (6.3, Q16).

The bridge is built on the `atspi` crate on `zbus` (section 8). Several community servers already do this on Linux (section 8.2). They are useful as design references.

### 5.2 What the toolkit must provide (input for D-006)

The bridge is only as good as the tree. C4 already requires a complete tree. This is what "complete" has to mean for an assistant. It is stated for both candidates; it doesn't recommend either. Examples are from `D-006-measurements.md` §M6/§M7 and `D-006-agent-test.md`.

| # | Requirement | Why an assistant needs it | Seen in the prototypes |
| --- | --- | --- | --- |
| A1 | **The tree is published.** Every widget becomes an AccessKit node and reaches AT-SPI. | Without it the bridge sees nothing. | libcosmic: 26 of 26 checks missing; the app is one unnamed `frame` with no children in every state. In the agent test, all three agents found that application code can't fix this. |
| A2 | **Correct roles:** window, dialog (modal), menu, menu bar, menu item, list/grid/table, **row**, **column header**, cell, tree item, tab, button, check box, text field, password field. AccessKit has all of these (`Row`, `ColumnHeader`, `Menu`, `MenuItem`, `Dialog`, `AlertDialog` and others) [12]. | "Open the third file" or "choose *Copy Path*" needs a row or menu item node to act on. | Slint 1.18.1: rows, column headers and menu items are `label`s, and the dialog is a `panel`. Its role enum lacks these roles, so app code can't fix it (#11). |
| A3 | **States:** focused, **selected**, checked, expanded, disabled, modal, multiselectable. | The assistant must check what it did, and the action log must record it. | Neither prototype exposes row selection. M7 steps 7 and 12 (selection after End/Home, 10k list) can't be verified through AT-SPI, for either toolkit. |
| A4 | **Actions routed to the widget,** not faked as input: AccessKit's `Click`, `Focus`, `SetValue`, `ReplaceSelectedText`, `SetTextSelection`, `Expand`/`Collapse`, `ShowContextMenu`, `ScrollIntoView`, `Increment`/`Decrement`, `CustomAction` [12]. | Semantic actions work regardless of focus, layout and timing. On the NUC, a stray key in the libcosmic walkthrough landed one row off (M7 steps 8/9). | Not measured in M6/M7; needs a check in D-006 or follow-up work. |
| A5 | **Virtualised lists stay addressable:** row count, row index and position in set (AccessKit `set_row_count`, `set_row_index`, `set_position_in_set`, `set_size_of_set` [13]), and `ScrollIntoView` or select by index. | An assistant must reach item 9,999 of 10,000 without paging through the list. | M7 step 12: "not verifiable (no rows in the tree)" for Slint, and no tree at all for libcosmic. |
| A6 | **Popups and dialogs belong to their app**, as children of the window or with a parent relation, with a name and the right role. | The assistant must find the menu it just opened. | Slint's context menu is a separate `frame` named `d006-slint`, not a menu under the window. |
| A7 | **Stable identifiers** that survive a restart: the toolkit sets AccessKit `author_id` [13] on every control, and it shows up as the AT-SPI `AccessibleId` property (testable from AT-SPI). On AccessKit's `main` branch the AT-SPI adapter already returns `author_id` as `AccessibleId` [24]. I didn't check whether the released `accesskit_unix` 0.24.1 does. | Saved assistant workflows and action-log entries can name a control ("Files › toolbar › *Up*"), not an object path that changes every launch. | Not measured. |
| A8 | **The tree can be on whenever assistant integration is on,** within budget. AccessKit builds the tree only while assistive technology is active, and M1–M5 ran with it off (measurements, deviation 5). | If assistants are on, the tree is on, and the §7 budgets (M1–M5) must hold with it on. | Not measured with the tree on. Proposed as a follow-up measurement for D-006 (section 9). |
| A9 | **Password fields don't expose their text,** and nodes can be marked sensitive. | Keeps secrets out of tool results and so out of cloud models (C10: "sensitive data … needs confirmation every time"). | Not measured. |

### 5.3 What native apps need to expose actions as MCP tools with little code

Goal: an app developer declares an action once, and gets the menu or palette entry, the keyboard shortcut, the accessibility action and the MCP tool from that one declaration. Proposal for the SDK (C4), independent of D-006:

1. **One action registry per app** in the shared app skeleton (C5). Each action has a stable ID, title, description, a parameter type (a Rust struct), a result type, and a side-effect class (R/W/D/O as in section 3).
2. **Generated MCP tools.** The SDK turns the registry into tool definitions. The `inputSchema` and `outputSchema` come from the Rust types (`rmcp` already does this with `schemars` and its `#[tool]` macro [9]), and the annotations come from the side-effect class. Calls are dispatched to the same handler the menu uses, so a tool call can't do anything the user can't do, and it goes through the app's undo stack (C5 Files' undoable operations).
3. **Structured results.** Tools return `structuredContent` matching `outputSchema` [5], not text scraped from the UI. That makes results checkable and smaller, and they are less useful as a prompt-injection channel than free text (they still carry user content; section 6.3).
4. **One server per running app,** activated over D-Bus as in 4.2. For a single-window app this is about one call in `main`, which the skeleton can make.
5. **Existing standard:** the freedesktop `org.freedesktop.Application.ActivateAction` D-Bus method (Desktop Entry spec, `DBusActivatable` [14]) already lets other processes trigger an app's named actions, but without descriptions or schemas. It is a precedent, not a channel to use: any session-bus peer can call it, so exporting the registry through it would create a second path with no broker in it. The proposal is that the skeleton **doesn't** export registry actions there, apart from the plain `Activate` and `Open` that launching needs. Apps built with an assistant (C12) get the same registry, so they get the agent interface without extra work.

How this fits each toolkit candidate, as a fact rather than a ranking: in iced/libcosmic every user action is already a `Message` variant handled in `update`, which maps directly onto a tool dispatcher. In Slint, actions are callbacks declared in `.slint` and implemented in Rust, so the registry lives on the Rust side and binds those callbacks. Neither needs toolkit changes for 5.3. Only section 5.2 depends on the toolkit.

## 6. Where the permission broker sits

### 6.1 Call path (proposal)

```
 Assistant process (sandboxed)                               ┌──────────── shell-owned UI ─────────────┐
 ┌──────────────────────┐                                    │ indicator · confirmation · stop switch  │
 │ model (local / cloud)│◄─ prompt, context ─┐               │ action log · Privacy page (C10)         │
 │ MCP client           │                    │               └──────────────▲──────────────────────────┘
 └──────────┬───────────┘                    │                              │ (D-Bus, not MCP)
            │ MCP over Unix socket (T2)      │ (cloud: outbound data,       │
            ▼                                │  see 6.4)                    │
 ┌──────────────────────────────────────────────────────────────────────────┴──┐
 │ PERMISSION BROKER (MCP gateway)                                             │
 │  1 identify assistant (peer creds / Flatpak app ID)                         │
 │  2 tools/list: show only granted servers and tools, prefixed by server      │
 │  3 tools/call: check capability + arguments (paths, apps, keys)             │
 │  4 confirm D / O / sensitive calls in shell-owned UI, never via assistant   │
 │  5 forward; check result (size, sensitivity, injection marking)             │
 │  6 append to action log; drive indicator; obey stop switch                  │
 └───────┬───────────────┬────────────────┬─────────────────┬──────────────────┘
         │ T2            │ D-Bus + fd     │ T1 sandboxed    │ T4 HTTPS (outbound)
         ▼               ▼                ▼                 ▼
   system servers   native & Flatpak   third-party       remote servers
   (Settings, Files,  app servers      stdio servers
    Windows, …, a11y bridge → AT-SPI → apps without MCP)
```

### 6.2 Placement options

| Option | Description | For | Against and security risks |
| --- | --- | --- | --- |
| **P1 Gateway** (above) | The broker is the only server any assistant sees, and it forwards to backends. | One enforcement point for every assistant and server, including third-party ones. The broker sees every call, argument, result and elicitation (MCP is stateless, section 2), which is what the action log, indicator and stop switch need. Assistants can be untrusted. | A single point of failure and a high-value target: a bug in the broker is a bug everywhere, so it must be small, in Rust (D-009) and audited. Adds one hop to every call; needs a latency budget (section 7, Q15). |
| **P2 Check in each server** | Each server asks the broker over D-Bus "may assistant X do Y?" before acting. | Defence in depth. Works even if a server is reached another way. | Every server must get it right, and third-party servers can't be trusted to. The broker doesn't see results, so it can't log or check them. On its own it doesn't meet C12. |
| **P3 Check in the assistant** | The assistant host enforces the rules. | Simplest. | A third-party or compromised assistant ignores the rules. **Confused deputy:** a prompt-injected model asks, the same process approves. Doesn't meet "assistants cannot easily do harm" (§2 priority 4). |

**Recommendation (proposal):** P1, plus P2 for system servers. System servers accept only the broker as a peer (mechanism in 4.2, Q18), and check the identity the broker passes along before D or O actions. P3 is ruled out as the enforcement point. The broker owns the confirmations. An assistant may still offer its own UI, but that UI never counts as a confirmation.

### 6.3 Risks per path and what the placement does about them

| Risk | Where it enters | What P1 makes possible (D-012 decides which to use) |
| --- | --- | --- |
| **Prompt injection through tool results** | Any R tool that returns content someone else wrote: `files.read_text`, `notifications.list`, `search.query`, `a11y.read_text` and `get_tree` (web pages, mail and chat inside apps), third-party server results. | The broker knows which results come from untrusted content. It can mark them, cap their size, and after such a result require confirmation for the next D or O call (taint tracking). It can't remove injection; MCP has no mechanism for that [5]. |
| **Prompt injection through app content via the bridge** | The AT-SPI tree of any window, including text the assistant didn't ask for. | Scope the bridge to granted apps. Never let it read or act on shell, broker, portal or Settings › Privacy windows. |
| **Confused deputy** | (1) The model is tricked into using the assistant's rights for an attacker. (2) A server with more rights than the assistant acts for it: the Files server can read any user file, the bridge can click any button. (3) **The bridge clicks *Allow* in a portal or confirmation dialog.** | (1) Per-assistant capabilities and argument checks (paths, apps). (2) Servers act with the caller's capability (passed by the broker), not their own full rights. (3) Hard rule: confirmation, portal and stop-switch UI is excluded from the bridge and from synthetic input, and confirmations accept only real user input events. |
| **Malicious third-party MCP servers** | Tool descriptions carrying instructions ("tool poisoning"); false annotations (`readOnlyHint` on a delete); tool definitions that change after approval (`listChanged`); name collisions that shadow system tools; the server binary itself (local server compromise [7]). | The broker prefixes tools by server (the spec says to [5]) and never lets third-party names shadow system ones. It ignores third-party annotations for confirmation decisions. It pins approved tool definitions and asks again when they change. It runs servers sandboxed (T1 with bubblewrap or Flatpak) and shows the exact command at install [7]. |
| **Data leaving the machine** | (a) Remote servers (T4); (b) local tools with `openWorldHint` (send, pair, connect); (c) data sent as tool arguments, for example a URL with file content in it; (d) the bridge typing into a browser or mail app; (e) **context sent to a cloud model**, which goes from the assistant to its provider and not through MCP. | (a)–(c): the broker sees them and C12 requires confirmation every time. (d): only if a11y actions in network-capable apps count as outbound (section 7, Q7). (e): **P1 alone can't see this.** See 6.4. |
| **Assistant impersonation** | An unsandboxed process connects to the broker socket and claims to be a trusted assistant. | Only Flatpak app IDs (or other kernel-verified sandbox identities) count as identities. How to treat unsandboxed callers is open: refuse them, or give them only default rights (Q2). |
| **Bypass: same-UID access to "broker-only" sockets** | `SO_PEERCRED` can't tell the broker from any other process of the user (4.2). | The broker's pidfd checked against the image binary (i), or the broker as its own system user (ii). Under (i), unsandboxed same-UID code is outside the model (Q18). |
| **Bypass: app servers over D-Bus** | Any session-bus peer calls an app's fd-handoff method, or `org.freedesktop.Application.ActivateAction`, and gets an unbrokered path (4.2, 5.3). | The app skeleton checks that the caller is the broker (pidfd under (i), reversed connection under (ii)). Registry actions are not exported through `ActivateAction`. |
| **Bypass: direct AT-SPI** | AT-SPI has no access control. Any unsandboxed process can read and act on every app's tree, which is how screen readers work. A Flatpak assistant gets past Flatpak's a11y filter [23] with `--talk-name=org.a11y.Bus`, `--socket=session-bus` or `--filesystem=xdg-run/at-spi`. | Can't be closed for unsandboxed code without changing AT-SPI, which would also affect screen readers. For sandboxed assistants: these permissions make an app ineligible as an assistant, or are stripped from it (Q16). |
| **Bypass: the assistant's own sandbox permissions and portals** | Every Flatpak can call `org.freedesktop.portal.*`, so an assistant can request RemoteDesktop (synthetic input) or ScreenCast directly; the only gate is the portal dialog, and restore tokens make the grant persistent. Static permissions such as `--filesystem=home`, `--share=network` or `--talk-name=org.freedesktop.NetworkManager` let it act with no MCP involved. None of this reaches the action log, indicator or stop switch. | Options for D-012 (Q16): deny registered assistants the RemoteDesktop and ScreenCast portals, or route those grants through the broker; strip or refuse static permissions beyond a fixed allowlist; treat network access as outbound (ties into 6.4). |
| **Remote servers: token theft and misuse** | The broker holds OAuth tokens for remote servers. A malicious remote server hands out metadata URLs (SSRF), `javascript:` or shell-injecting authorization URLs, or tries a mix-up attack [7]. | Assistants never see tokens, and no token is passed through. CIMD instead of DCR, `iss` validation, URL scheme allowlist, no shell to open URLs, private-range blocking for metadata fetches [7]. Token storage is open (Q17). |
| **Stop switch evasion** | Long tasks (`io.modelcontextprotocol/tasks`), calls already forwarded, a third-party server that ignores cancellation. | On stop, the broker refuses new calls, sends cancellations, drops connections, and can freeze or kill sandboxed server processes (systemd scope or cgroup). |

### 6.4 The cloud-model preview is outside MCP

C10 requires that "before data goes to a cloud model, the user sees what will be sent", and C12 that "data leaving the machine always needs confirmation". The model call isn't an MCP message. A third-party assistant sends its context, including tool results, straight to its provider. The broker can confirm what goes out through tools, but it can't show what the assistant sends to its own model. D-012 has to choose a mechanism, for example:

- **(a)** assistants have no network access, and cloud model calls go through a system model gateway that shows the preview; or
- **(b)** only our own assistant host may use cloud models, and third-party assistants are local-only; or
- **(c)** something else.

This is the largest open question in this write-up (section 7, Q1).

## 7. Open questions for D-012 (not decided here)

1. **Cloud-model preview path** (6.4): how does the OS see, and let the user confirm, what an assistant sends to its cloud model? Gateway, no network for assistants, or only our own assistant host?
2. **Assistant identity:** is a Flatpak app ID the only accepted identity? What rights does an unsandboxed or CLI assistant get?
3. **Capability granularity:** per server, per tool, or per tool with argument limits (folders, apps, settings keys)? How do capabilities map onto existing permission stores (the Flatpak permission store, portal grants) so the Privacy page shows one list (C10)?
4. **Default capabilities** for a new assistant, and what "relax confirmations per assistant" may cover, given that D, O and sensitive actions stay confirmed every time (C12).
5. **What counts as D, O and sensitive** for each system tool in section 3, and who maintains that list. Can a server change its own class?
6. **Accessibility actions:** `a11y.do_action` can't be classified. Confirm every action, confirm per app, or classify by role and name (for example buttons named *Delete* or *Send*)?
7. **Outbound through the UI:** do a11y actions in network-capable apps (browser, mail, chat) count as "data leaving the machine"?
8. **Prompt-injection policy:** after untrusted content enters the context, is confirmation required for the next D or O call, for the rest of the task, or not at all?
9. **Confirmation UI:** shell-owned dialog or notification; what it shows (tool, arguments, diff or preview); whether keyboard-only and screen-reader users can confirm safely, with the dialog unreachable from the bridge.
10. **Elicitations from servers** (MRTR `input_required`): does the broker show them in its own UI, or forward them to the assistant? URL-mode elicitation opens a web page: is that outbound?
11. **Action log:** what it stores (arguments, results, or only summaries), how long, whether it is encrypted, and whether the user can undo from it.
12. **Stop switch semantics:** stop only, or stop and roll back undoable actions? Where it lives (shell, global shortcut) and whether it must work when the shell is busy.
13. **Flatpak assistant access:** a static `--talk-name` now and a new portal later (4.4), or a portal from the start?
14. **Discovery marker** for app servers: desktop entry key or AppStream `<provides>` (4.3), and whether it is proposed upstream to freedesktop.
15. **Latency budget** for the broker hop and confirmations: §7 has none for assistant actions; is one needed?
16. **Assistant eligibility:** which static Flatpak permissions (`--socket=session-bus`, `--talk-name=org.a11y.Bus`, `--filesystem=home` or `xdg-run/at-spi`, `--share=network`, system-service talk names) and which portal grants (RemoteDesktop, ScreenCast, restore tokens) make an app ineligible to register as an assistant, or are stripped from it? Or are they allowed and only logged?
17. **Remote-server tokens:** where does the broker store OAuth tokens for remote servers (Secret Service keyring, its own encrypted store, memory only), and how does the user see and revoke them on the Privacy page?
18. **Broker identity:** does the broker run as the user, with pidfd checks, leaving unsandboxed same-UID code outside the model, or as its own system user with reversed app connections (4.2)?

## 8. Existing work worth reusing

### 8.1 Rust SDKs and crates (D-009: trustworthy, maintained, stable, worth its size)

| Crate | Licence | Maintenance (checked 2026-11-05) | MCP revision | Assessment |
| --- | --- | --- | --- | --- |
| **`rmcp`**, official SDK [9] | Apache-2.0 (the MCP project is moving from MIT to Apache-2.0; older contributions stay MIT) [15] | Maintained by the `modelcontextprotocol` organisation. 3.9.0 released 2026-11-05, 3.8.0 on 2026-10-26, 3.7.0 on 2026-10-22. ~4.1k GitHub stars, ~45 M downloads. MSRV 1.88. | 2026-07-28, compatible with 2025-11-25 and earlier | **Recommended.** Official, the most used, tracks the spec, and supports server and client. `transport-async-rw` covers Unix sockets and passed fds; `#[tool]` + `schemars` generates schemas (5.3). Feature flags keep it small: HTTP and auth only for the remote-server client. Uses tokio. Releases are frequent, so pin versions in `Cargo.lock`. |
| `rust-mcp-sdk` [16] | MIT | Community (`rust-mcp-stack`). 2.0.0 released 2026-08-27, ~200 stars, ~0.3 M downloads. MSRV 1.80. | 2026-07-28; claims 100% of the official conformance tests | Good fallback. Smaller community and a single organisation, so less trustworthy over time than the official SDK. |
| `zbus` [17] | MIT | Active. Latest is 6.2.1 (2026-11-01), but **`accesskit_unix` 0.24.1 requires `zbus ^5.19`** (5.19.0 released 2026-08-09) [25]. | n/a | For D-Bus activation, fd passing and the Settings, Connectivity and Notifications back ends. **Use the 5.x line that AccessKit pins**, not 6.x. Adopting 6.x would put two zbus major versions in the tree (a D-009 size point). Move to 6.x only together with AccessKit. |
| `atspi` [18] | Apache-2.0 OR MIT | Latest is 0.30.0 (2026-05-06, Odilia screen-reader project), but **`accesskit_unix` 0.24.1 requires `atspi ^0.29`** (0.29.0, 2025-09-18) [25]. | n/a | AT-SPI client for the bridge, built on `zbus`. Adds no new crate only at the version AccessKit pins (0.29). 0.30 is semver-incompatible and would duplicate it. Same rule as zbus: follow AccessKit's version. |
| `accesskit` / `accesskit_unix` [12] | MIT OR Apache-2.0 | 0.25.2 / 0.24.1, released 2026-10-25 | n/a | Already required by C4. Has all roles, states and actions in 5.2. The gaps are in the toolkits' use of it, not in AccessKit. |

No new language is added: the broker, servers, bridge and SDK parts are Rust (D-009). The stdio-to-socket shim is also Rust.

### 8.2 Existing Linux and desktop MCP work

None of these is from GNOME, KDE or freedesktop. A search on 2026-11-05 found no official MCP integration in any of them. The only KDE report found is one blog post about a third-party chat app adding MCP; it isn't a KDE project.

| Project | Language, licence | Status (2026-11-05) | What it does | Reuse? |
| --- | --- | --- | --- | --- |
| `nisavid/computer-use-linux` [19] | Rust, MIT | Created 2026-06, last push 2026-10-28, single maintainer, 0 stars | AT-SPI trees, window focus, screenshots, input through Wayland portals and `ydotool`, AT-SPI actions on GNOME | **Design reference** for the bridge (closest match: Rust, AT-SPI, Wayland). Too young and unvetted to depend on. |
| `isac322/kwin-mcp` [20] | Python, MIT | Created 2026-02, last push 2026-11-05, 77 stars | 29 tools on KDE Plasma 6 Wayland: AT-SPI tree, windows, input, D-Bus | Reference for the tool set. Not reusable: Python (D-009), and its input bypasses the RemoteDesktop portal through KWin's private EIS interface, which is the opposite of what we need for confirmations. |
| `Joao-Peterson/linux-desktop-mcp` [21] | Not stated, MIT | Created 2026-10, 0 stars | AT-SPI2: tree, find, actions, values, tables; tested on X11 | Reference for addressing elements by role and name instead of pixels. |
| `liufeicc/cc-computer-use` [22] | Python, MIT | Created 2026-09, 0 stars | AT-SPI on X11 | X11 only (D-001). No reuse. |
| MCP Registry [11] | Open source, MCP project | Active, ~7.4k stars | Public index of servers (`server.json`) | Possible later source for a "find servers" view in Software (C7); its metadata format could inform our manifest (4.3). Not needed for Phase 3. |
| xdg-desktop-portal, xdg-dbus-proxy, bubblewrap, Flatpak [10] | C, LGPL | The standard | Sandboxing, the a11y bus filter, portals | **Reuse as is.** Flatpak already filters the a11y bus so a sandboxed app can only register itself, not read other apps' trees [23]. The bridge must therefore run outside the app sandbox, as a system server reached only through the broker. |

## 9. Consequences

- **D-006** gets the requirements in 5.2 as input. For both candidates, A1–A3 and A5–A6 already show gaps in M6/M7. A4, A7, A8 and A9 aren't measured yet, and A8 changes the budget conditions: proposed as a follow-up check for #14, not done here.
- **D-012 (#32)** gets the call path (6.1), the placement options (6.2), the risk map (6.3), the cloud-preview problem (6.4) and the questions in section 7.
- **C4 SDK** gets the action registry proposal (5.3) as a Phase 3 design input. No card is created until D-006 and D-012 are decided.
- **No spec change is proposed** by this write-up. If the owner accepts 4.2 and 6.2, C12 could name the broker as the single MCP endpoint for assistants. That would be the owner's edit.

## Sources

1. MCP specification, revision 2026-07-28 (*Current*), versioning page: <https://modelcontextprotocol.io/specification/versioning> · specification: <https://modelcontextprotocol.io/specification/2026-07-28>
2. MCP 2026-07-28, Transports (custom transports, stdio framing): <https://modelcontextprotocol.io/specification/2026-07-28/basic/transports>
3. MCP 2026-07-28, Key changes: <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
4. MCP schema 2026-07-28 (`ToolAnnotations`, `Implementation`): <https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2026-07-28/schema.ts> · <https://modelcontextprotocol.io/specification/2026-07-28/schema>
5. MCP 2026-07-28, Tools (human in the loop, annotations untrusted, security considerations, MRTR): <https://modelcontextprotocol.io/specification/2026-07-28/server/tools>
6. MCP 2026-07-28, Deprecated features registry: <https://modelcontextprotocol.io/specification/2026-07-28/deprecated>
7. MCP, Security best practices (confused deputy, local server compromise, stdio, SSRF, scope minimisation): <https://modelcontextprotocol.io/specification/2026-07-28/basic/security_best_practices>
8. Desktop Notifications Specification: <https://specifications.freedesktop.org/notification-spec/latest/>
9. `rmcp`, official Rust SDK: <https://github.com/modelcontextprotocol/rust-sdk> · releases: <https://github.com/modelcontextprotocol/rust-sdk/releases> · crate: <https://crates.io/crates/rmcp>
10. Flatpak, exported directories (`exported_subdirs` in `common/flatpak-dir.c`): <https://github.com/flatpak/flatpak/blob/main/common/flatpak-dir.c> · xdg-desktop-portal: <https://github.com/flatpak/xdg-desktop-portal>
11. MCP Registry: <https://github.com/modelcontextprotocol/registry>
12. AccessKit `Role` and `Action`: <https://docs.rs/accesskit/latest/accesskit/enum.Role.html>, <https://docs.rs/accesskit/latest/accesskit/enum.Action.html> · repository: <https://github.com/AccessKit/accesskit>
13. AccessKit `Node` (`set_author_id`, `set_row_count`, `set_row_index`, `set_position_in_set`, `set_size_of_set`, `set_selected`, `set_modal`): <https://docs.rs/accesskit/latest/accesskit/struct.Node.html>
14. Desktop Entry Specification, D-Bus activation (`org.freedesktop.Application`): <https://specifications.freedesktop.org/desktop-entry-spec/latest/dbus.html>
15. MCP Rust SDK `LICENSE` (licence transition note): <https://github.com/modelcontextprotocol/rust-sdk/blob/main/LICENSE>
16. `rust-mcp-sdk`: <https://github.com/rust-mcp-stack/rust-mcp-sdk> · <https://crates.io/crates/rust-mcp-sdk>
17. `zbus`: <https://github.com/z-galaxy/zbus> · <https://crates.io/crates/zbus>
18. `atspi`: <https://crates.io/crates/atspi>
19. computer-use-linux: <https://github.com/nisavid/computer-use-linux>
20. kwin-mcp: <https://github.com/isac322/kwin-mcp>
21. linux-desktop-mcp: <https://github.com/Joao-Peterson/linux-desktop-mcp>
22. cc-computer-use: <https://github.com/liufeicc/cc-computer-use>
23. Flatpak, a11y bus proxy filter (`flatpak_run_add_a11y_dbus_args` in `common/flatpak-run-dbus.c`): <https://github.com/flatpak/flatpak/blob/main/common/flatpak-run-dbus.c>
24. AccessKit AT-SPI adapter, `accessible_id` returns `author_id` (`adapters/atspi-common/src/node.rs`, `main` branch, checked 2026-11-05): <https://github.com/AccessKit/accesskit/blob/main/adapters/atspi-common/src/node.rs>
25. `accesskit_unix` 0.24.1 dependencies (`zbus ^5.19`, `atspi ^0.29`): <https://crates.io/api/v1/crates/accesskit_unix/0.24.1/dependencies>
